# Calendar coverage (F16)

A calendar check suggests which poll options clash with the viewer's own calendars. It is advisory: it marks busy options as unavailable in the unsaved editor and never saves anything. This contract defines what counts as busy, what each source covers, and what the poll screen shows when a source cannot be checked. Web, iOS and Android follow the same rules.

The owner chose these policies on October 30, 2026:

- Google checks read the **primary calendar only**, and every client says so.
- An **all-day event is busy unless it is marked free**. iOS also skips birthday and subscribed calendars.
- A source that cannot be checked marks options **"Couldn't check"**, shows a banner naming the source, and offers a retry.

## Sources

| Source | Clients | What it reads |
| --- | --- | --- |
| Google Calendar | Web, iOS, Android | The primary calendar, through `check-calendar-conflicts` and Google FreeBusy. No provider token reaches a client. |
| Apple Calendar | iOS | Every EventKit calendar on the device, with full access. |
| Android Calendar | Android | Device calendars, through one `CalendarContract.Instances` query so recurring events are expanded. |

Reading other Google calendars would need the calendar-list scope. That means asking existing users to consent again and going through Google's sensitive-scope verification, so it is left for a separate change.

## What counts as busy

Google decides which of its events are busy. FreeBusy omits events marked free (transparent) and returns busy intervals as instants, so the app cannot tell an all-day event from a timed one there.

On device calendars, an event is **not** busy when it is:

- marked free,
- cancelled, or
- declined by the viewer.

Every other event is busy, including tentative ones and all-day events. On iOS, an all-day event is also skipped when its calendar doesn't support availability or it comes from a birthday or subscribed calendar, which is where birthdays and public holidays live. Timed events from calendars without availability support still count.

## Matching events to options

Options follow the [date/time contract](date-time-contract.md). An all-day option is one calendar date in the poll's zone; a timed option is an interval of instants. Intervals are half-open, so an event that ends exactly when an option starts does not clash.

| Option | Event | Busy when |
| --- | --- | --- |
| Timed | Timed | The intervals overlap. |
| All-day | All-day | The option's date (poll zone) falls within the event's dates. |
| All-day | Timed | The event overlaps the option's stored interval. |
| Timed | All-day | The option overlaps the event's dates, taken from start of day to start of day in the device zone. |

Device all-day events are floating dates. EventKit gives them local-midnight bounds with an end at 23:59:59 on the last date. `CalendarContract` stores them at UTC midnights. Both clients convert them to dates before matching, and widen their query by two days on each side so events in other zones are not missed.

Google results are always instants, so a Google all-day event in another zone can touch the neighbouring date of an all-day option. Device calendars do not have this limitation.

## Results

Each check returns, per source, either the set of busy option IDs or "could not be checked". The clients combine them:

| Option state | Rule | Shown as |
| --- | --- | --- |
| Busy | Any checked source reports it. | "Busy" badge; suggested as unavailable if the viewer has no response for it yet. |
| Couldn't check | Not busy, and at least one enabled source failed. | "Couldn't check" badge; the response is left unchanged. |
| Free | Not busy, and every enabled source was checked. | No badge. |

A failed source covers no options, so when any source fails, every option that isn't busy is marked "Couldn't check". The banner names the failed sources ("Google Calendar (primary calendar) couldn't be checked…") with a **Retry calendar check** action. After a check with no failures, a caption names what was read, for example "Checked Apple Calendar and Google Calendar (primary calendar)."

A source fails when:

- the backend returns an error or non-2xx status (provider errors, per-calendar FreeBusy errors, expired grants and connection changes all count),
- the response has `success` other than `true`, or a `coverage` other than `"primary"`. A client cannot honestly label coverage it does not recognise, so a backend that starts reading more calendars needs a client update first,
- device calendar permission is missing, or the provider query fails.

On web, a failed retry keeps the last known busy options for the same option set instead of clearing them. On every client, results from a superseded account or connection are discarded under the existing [session contract](session-lifecycle.md).

## Backend response

`check-calendar-conflicts` is unchanged by F16. A successful response is:

```json
{ "success": true, "coverage": "primary", "conflictingIds": ["option-id"] }
```

Anything the backend cannot fully check is an error response, never a success with an empty list. `supabase/functions/_shared/calendar/calendar_test.ts` covers provider and per-calendar failures and asserts the `coverage` value.

## Tests

| Platform | Tests |
| --- | --- |
| Web | `tests/web-session-lifecycle.test.mjs` (failure, unrecognised or missing coverage, retry); `tests/web-availability.test.mjs` (rendered badges, banner and caption) |
| iOS | `apps/mobile/Tests/CalendarCoverageTests.swift`: event filtering, date matching across zones and the Chicago fall-back day, result combination, and Google failure or unrecognised coverage through the real service transport |
| Android | `CalendarCoverageTest.kt` (the same matching cases); `ReviewedIsolationTest.kt` (device and Google failures through the service) |

Real device calendars and live Google accounts are not exercised by these tests.
