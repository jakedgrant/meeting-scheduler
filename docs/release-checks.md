# Release checks

This page lists the deterministic checks that run in GitHub Actions, what each one covers, and which ones the repository owner can make required. It belongs to finding F24 in the [architecture review](architecture-review-2026-10-21.md#f24-automated-release-checks-do-not-cover-the-system). The Claude Code workflows (`claude.yml`, `claude-code-review.yml`) and the scheduled calendar maintenance job aren't release checks and aren't listed.

## Checks

| Workflow and job | Runs on | Covers |
| --- | --- | --- |
| Web / `web-availability-and-build` | Every pull request and push to `main` | Generated database types match the migrations; every `tests/web-*.test.mjs` suite; `svelte-check`; the production build |
| Architecture database regressions / `authorization-and-command-suites` | Every pull request and push to `main` | Replays the migrations in PGlite and runs every `tests/*.test.mjs` suite that isn't a web or concurrency suite: authorization, participant access, membership, account deletion, commands, creation, dates, reads, required columns, calendar, billing and the diagnostics guard |
| Architecture database regressions / `command-concurrency`, `creation-concurrency` | Every pull request and push to `main` | Real lock waits between independent sessions on a disposable PostgreSQL server |
| Billing webhooks / `billing-webhooks` | Every pull request and push to `main` | Billing database suite; type checks, offline Deno tests and lint for the billing functions |
| Calendar security / `calendar-security` | Every pull request and push to `main` | Calendar database suite; type checks and offline Deno tests for the calendar functions |
| Android / `android-build-and-signing` | Pull requests and pushes to `main` that change `apps/android/**`, the shared date or entitlement fixtures, or the workflow | Debug and instrumentation builds, JVM unit tests, and the release-signing checks in [Android release signing](android-release-signing.md) |
| Android / `android-emulator-tests` | Same paths as the Android job | Every instrumented test (`connectedDebugAndroidTest`) on an API 34 x86_64 emulator: Activity lifecycle, auth deep links and screen-model recreation |
| iOS package regressions / `app-launch` | Same paths as the package job | Builds the app wrapper for a fresh iOS 26 simulator, launches it signed out and fails if it exits, isn't running after 15 seconds or leaves a crash report |
| Dependency advisories / `npm-advisories` | Every pull request, push to `main`, weekly and on demand | Fails on high or critical advisories in production dependencies of the root and web lockfiles; lists the full tree, development dependencies included, in the job summary |
| Dependency advisories / `swiftpm-advisories` | Same as above | Fails on any known advisory (osv-scanner) in the two `Package.resolved` files |
| iOS package regressions / `package-regressions` | Pull requests and pushes to `main` that change `apps/mobile/**`, the shared fixtures, the workflow or its scripts | `ServiceSet` key check; package build and every package test on a new iOS 26 simulator; the app wrapper build; the committed package pins stay unchanged |

Each workflow installs locked dependencies: `npm ci` from the committed lockfiles, `deno --frozen`, the Gradle wrapper, and SwiftPM restricted to `Package.resolved`. Every run starts from a fresh checkout on a hosted runner, which is the clean-checkout build the review asks for.

Test files are discovered rather than listed. `npm run test:web` runs every `tests/web-*.test.mjs` file and `npm run test:database` runs the rest except `tests/concurrent-*.test.mjs`, so a new suite runs in CI without a workflow edit. The two concurrency suites need their own server and are named in the workflow. Gradle runs every JVM test class and the iOS job runs every test in the package's `MeetingSchedulerTests` target.

## What isn't covered

- The emulator and launch jobs use no account, secret or test backend: the instrumented tests sign in to nothing, and the iOS app is launched signed out. The signed-out iOS app may still make anonymous requests to the hosted Supabase and RevenueCat projects, and the check doesn't depend on the results. Neither job signs in, so no flow that needs a test backend and accounts is exercised. The iOS wrapper has no UI test target; the launch check uses `simctl`.
- `AppWrapperConfigurationTests` reads the wrapper's source `Info.plist` and entitlements. It checks the keys the package depends on (the auth callback URL scheme, the full calendar access description and Sign in with Apple), not the bundle Xcode produces.
- Nothing checks hosted state: applied migrations, grants, secrets, deployed functions or provider configuration. Those are the owner actions in the [remediation progress](architecture-remediation-progress.md#hosted-rollout-and-owner-actions).
- Gradle dependencies aren't scanned in CI: the app keeps no lockfile for a scanner to read, so only Dependabot covers them. Advisories in development-only npm dependencies are reported, not enforced.

## Making checks required

Required checks are a repository setting, so the owner has to configure them in a branch ruleset or branch protection for `main`. The jobs that run on every pull request, including the two advisory jobs, can be required as they are. The two concurrency jobs run once per PostgreSQL version, so each reports two checks, and those are the names to enter:

- `web-availability-and-build`
- `authorization-and-command-suites`
- `command-concurrency (17)` and `command-concurrency (18)`
- `creation-concurrency (17)` and `creation-concurrency (18)`
- `billing-webhooks`
- `calendar-security`
- `npm-advisories`
- `swiftpm-advisories`

The two advisory jobs read live advisory databases, so a newly published advisory can fail a pull request that changed no dependency, which makes them less deterministic than the other checks. Clear one by updating the dependency (Dependabot proposes the update), or take the job off the required list while an update is pending.

Don't require the Android or iOS jobs while their workflows filter on paths. GitHub leaves a required check from a workflow that a path filter skipped as pending, so a web-only pull request couldn't merge. To require them, first move the path test into the workflow: run the job on every pull request and skip the build steps when nothing relevant changed, so the job still reports success. That spends a macOS runner start on every pull request.
