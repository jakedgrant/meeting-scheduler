# Integration diagnostics (F27)

Logs and error responses help someone trace a failure, and they must not carry credentials or personal data. This contract sets what each backend function and client may log, how to follow one failure through the system, and which alerts the project owner needs to set up. F17's [calendar check limits](#calendar-check-limits) are here too, because their measurements come from the same log lines.

## Backend logs

Every Edge Function logs through `logEvent` in `supabase/functions/_shared/diagnostics.ts`, which writes one JSON line. Its parameter type admits only these fields:

| Field | Meaning |
| --- | --- |
| `component` | The part of the backend that logged, such as `calendar_request` or `billing_worker`. |
| `code` | A stable code, such as `ok`, `rate_limited` or `provider_unavailable`. |
| `requestId` | A random UUID for one HTTP request. |
| `jobId` | The opaque ID of a queued revocation job or a check admission. |
| `kind` | The calendar endpoint: `connection`, `conflicts`, `callback` or `maintenance`. |
| `status` | The HTTP status returned. |
| `durationMs` | Time spent handling the request. |

The helper copies these fields by name, so anything else in the object it receives is dropped. Headers, request and provider bodies, user IDs, email addresses, tokens, and raw provider or database errors have no field. `code`, `component` and the ID fields accept any string, so callers must pass only stable codes and opaque IDs there.

## Tracing a failure

Responses from the calendar handler carry `X-Request-Id`, and failures repeat it as `requestId` in the JSON body. Search the function logs for that value to find the matching line. The conflict-check clients don't show or log this ID, so capture it from a network trace. Without one, filter by `kind`, `code` and time. A startup configuration failure happens before the handler runs, so it returns 503 with no ID and logs `calendar_runtime` `configuration_unavailable`.

A callback that passes state and return-target validation ends in a redirect, so its `calendar_request` line says `ok` with status 303 even when the connection failed. A callback rejected earlier returns an error and logs its code on the `calendar_request` line. The `calendar_oauth` line with the same request ID records the real outcome: `connected`, `cancelled` or `failed`. A failure that throws also logs its reason there.

A billing webhook that can't store an event and a worker that fails while claiming or processing an account return 503 with `requestId` in the body, and the worker's log line carries the same ID. The ID identifies the invocation, not the account: no billing log line names a customer. Use the [billing checks](billing-webhooks.md#recovery-and-diagnostics) to find the affected accounts. `configuration_unavailable` responses carry no ID. A retried Google revocation logs the revocation job's `id`.

Public errors contain a stable code, and calendar errors add a fixed message. They never contain provider or database text.

## Client logs

| Client | Rule |
| --- | --- |
| iOS | `FailureLog` writes to the unified log. The operation must be a `StaticString`, and only it and the error's domain and code are public. The full error is logged as `.private`; runtime redaction isn't tested. |
| Android | `FailureLog` logs the operation and exception class. Debug builds also log the exception. Operations and other `Log` calls carry fixed text, or a Credential Manager type or class name. |
| Web | `console` calls take one fixed string. |

RevenueCat's own log level follows the build type on both native clients ([F26](android-release-signing.md#native-billing-log-levels-f26f27)).

`tests/diagnostics-guard.test.mjs` (`npm run test:diagnostics`, also part of `npm run test:database`) fails if any source logs outside these rules: `print` or `println`, an exception message passed to `Log`, a `console` call with anything but a fixed string, or an Edge Function using `console` directly. It is a line-based source check, so it catches the usual forms rather than every possible one.

The native and web clients still show some SDK error text in on-screen messages, such as the Android sign-in error. That is outside this contract, which covers logs.

## Calendar check limits

The owner set these on November 2, 2026. Each user has a budget for `check-calendar-conflicts`:

| Limit | Value |
| --- | --- |
| Checks per minute | 20 |
| Checks per hour | 200 |
| Checks in flight | 2 |

Both windows slide. The owner also decided that Google Calendar stays available to every signed-in user for now, so the backend adds no entitlement check. The paywalls still list calendar integrations as a paid feature, and that mismatch is an open product decision.

### How a check is admitted

Validation runs first, so a malformed request spends no budget. `CalendarService.conflicts` then calls `calendar_admin('admit_check')`, which takes a per-user advisory lock, counts the user's rows in `private.calendar_check_admissions`, and either records an admission or returns how long to wait. Edge Function instances share no memory, so the count has to live in the database.

- **Over budget:** HTTP 429 with error `rate_limited`, a `Retry-After` header and `retryAfter` in the body. No token is read and Google is not called. The attempt isn't recorded, so retrying can't extend the wait.
- **Storage unavailable:** the check fails with 503 before any provider work. Limits fail closed.
- **Finished:** `finish_check` frees the in-flight slot, and the row keeps counting towards the budget. If that call fails or a worker dies, the 60-second lease frees the slot, and a check's four provider calls at 10 seconds each fit inside it.
- **Retention:** rows hold a user ID and timestamps, and are deleted with the account. Admitting a check deletes that user's rows older than an hour. Once configured, the [maintenance workflow](calendar-credentials.md#maintenance-and-rotation) also removes up to 1,000 such rows across all users every five minutes. Until then, an inactive user's rows stay until that user's next check or account deletion.

A failed check still spends budget, because it may already have used Google quota. Only conflict checks are limited; `calendar-connection` calls Google only to revoke a grant, and that work is already bounded to 20 jobs per call.

### What clients show

A 429 needs no dedicated client handling. Web, iOS and Android already treat any unsuccessful check as unknown, so a 429 marks options "Couldn't check" with the retry banner from the [coverage contract](calendar-coverage.md#results). None retries automatically.

### Provider use and caching

One check makes one FreeBusy call regardless of how many options it covers, or two if Google rejects the access token and a refresh succeeds. The hourly limit caps one account at 4,800 checks a day, so at most 9,600 FreeBusy calls. FreeBusy quota and rate-limit errors are logged as `provider_rate_limited`, separate from `provider_unavailable`. Token-endpoint throttling stays `provider_unavailable`.

There is no cache. The plan adds one only if measurements justify it, and no hosted measurements exist yet.

## Measuring latency and quota

Every request the handler processes, except a successful `OPTIONS` preflight, logs one `calendar_request` line with `kind`, `status`, `code` and `durationMs`. Those lines answer the F17 questions:

- Check latency: `durationMs` where `kind` is `conflicts` and `code` is `ok`.
- Budget pressure: the share of `conflicts` lines with `code` of `rate_limited`.
- Google quota: the count of `provider_rate_limited`, against `conflicts` lines that reached Google. Exclude `rate_limited`, validation codes and `reconnect_required`. This approximates provider use, because a check can make two FreeBusy calls.

## Alerts and retention

Alerts live in hosted configuration, so this repository can't create them. The project owner is responsible for setting them up and for choosing a log retention period before launch.

| Alert on | Source | Why |
| --- | --- | --- |
| Any `cleanup_required` | `calendar_oauth` | A newly issued Google token could be neither stored nor revoked. |
| Any `configuration_unavailable` | `calendar_runtime`, `billing_runtime`, `billing_webhook`, `billing_worker` | A function is missing configuration, so every request to it fails. |
| Sustained `provider_rate_limited` | `calendar_request` | Google is throttling FreeBusy for the project or for one user. |
| Sustained 5xx `status` | `calendar_request` | Storage or provider outage. |
| Sustained high `durationMs` on `conflicts` | `calendar_request` | Checks are slowing down. The owner sets the threshold after the first hosted measurements. |
| Sustained `rate_limited` | `calendar_request` | The budget may be too tight, or a client may be looping. |
| Repeated `retry_scheduled` or queue age | `calendar_revocation`, [queue checks](calendar-credentials.md#maintenance-and-rotation) | Google grants are not being revoked. |
| `accept_failed`, or any `error`-level line | `billing_webhook`, `billing_worker` | Purchases aren't being processed. See the [billing checks](billing-webhooks.md#recovery-and-diagnostics). |

## Verification

`npm run test:calendar:edge` checks admission, 429 behaviour, callback outcomes and the log allowlist, and asserts that tokens, cookies, emails and user IDs don't appear in captured logs from successful and failing flows. `npm run test:billing:edge` checks that a worker failure's response and log line share a request ID, and that missing webhook or worker auth is logged. `npm run test:calendar:db` checks the limits, windows, lease expiry, pruning and account deletion against PGlite.

`npm run test:commands:concurrent` needs `TEST_DATABASE_URL` naming a fresh disposable PostgreSQL database. It checks that a waiting admission can't exceed the in-flight limit, and `architecture-database.yml` runs it in CI. `FailureLogTests.swift` and `FailureLogTest.kt` check the native summaries; whether the system redacts `.private` values isn't tested. Hosted alerts, log retention and real Google quota behaviour haven't been exercised.

## Rollout

Apply `20261102152851_calendar_resource_controls.sql` before deploying the calendar functions. The new function code calls `admit_check`, so running it against the old schema would fail every conflict check. Billing functions gain only log and response fields, so they can deploy in any order.

After deploying, run one check and confirm a `calendar_request` line with `kind` `conflicts` and `code` `ok`. To roll back, redeploy the previous calendar functions and leave the migration applied. The previous code doesn't use the new table, and `calendar_admin` keeps its earlier operations.
