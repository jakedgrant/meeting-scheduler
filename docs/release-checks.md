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
| Android / `android-build-and-signing` | Every pull request and push to `main`; the work runs only when [Android paths change](#how-the-gating-works) | Debug and instrumentation builds, JVM unit tests, and the release-signing checks in [Android release signing](android-release-signing.md) |
| Android / `android-emulator-tests` | Same as the Android job | Every instrumented test (`connectedDebugAndroidTest`) on an API 34 x86_64 emulator: Activity lifecycle, auth deep links and screen-model recreation |
| iOS package regressions / `app-launch` | Same as the package job | Builds the app wrapper for a fresh iOS 26 simulator, launches it signed out and fails if it exits, isn't running after 15 seconds or leaves a crash report |
| Dependency advisories / `npm-advisories` | Every pull request, push to `main`, weekly and on demand | Fails on high or critical advisories in production dependencies of the root and web lockfiles; lists the full tree, development dependencies included, in the job summary |
| Dependency advisories / `swiftpm-advisories` | Same as above | Fails on any known advisory (osv-scanner) in the two `Package.resolved` files |
| Dependency advisories / `gradle-advisories` | Same as above | Fails on any known advisory (osv-scanner) in `apps/android/app/gradle.lockfile`, the locked app classpaths; lists advisories in the build plugins' `buildscript-gradle.lockfile` in the job summary without failing |
| iOS package regressions / `package-regressions` | Every pull request and push to `main`; the work runs only when [iOS paths change](#how-the-gating-works) | `ServiceSet` key check; package build and every package test on a new iOS 26 simulator; the app wrapper build; the committed package pins stay unchanged |

Each workflow installs locked dependencies: `npm ci` from the committed lockfiles, `deno --frozen`, the Gradle wrapper with locked dependencies (see [Updating Gradle locks](#updating-gradle-locks)), and SwiftPM restricted to `Package.resolved`. Every run starts from a fresh checkout on a hosted runner, which is the clean-checkout build the review asks for.

Test files are discovered rather than listed. `npm run test:web` runs every `tests/web-*.test.mjs` file and `npm run test:database` runs the rest except `tests/concurrent-*.test.mjs`, so a new suite runs in CI without a workflow edit. The two concurrency suites need their own server and are named in the workflow. Gradle runs every JVM test class and the iOS job runs every test in the package's `MeetingSchedulerTests` target.

## What isn't covered

- The emulator and launch jobs use no account, secret or test backend: the instrumented tests sign in to nothing, and the iOS app is launched signed out. The signed-out iOS app may still make anonymous requests to the hosted Supabase and RevenueCat projects, and the check doesn't depend on the results. Neither job signs in, so no flow that needs a test backend and accounts is exercised. The iOS wrapper has no UI test target; the launch check uses `simctl`.
- `AppWrapperConfigurationTests` reads the wrapper's source `Info.plist` and entitlements. It checks the keys the package depends on (the auth callback URL scheme, the full calendar access description and Sign in with Apple), not the bundle Xcode produces.
- Nothing checks hosted state: applied migrations, grants, secrets, deployed functions or provider configuration. Those are the owner actions in the [remediation progress](architecture-remediation-progress.md#hosted-rollout-and-owner-actions).
- Advisories in development-only npm dependencies and in the Android build plugins' own dependencies are reported, not enforced. The Gradle scan reads the locked classpaths only, so it doesn't see build tools that aren't locked (lint, the Kotlin compiler, the test-device runner).

## Making checks required

Required checks are a repository setting, so the owner has to configure them in a branch ruleset or branch protection for `main`. Every job below reports a result on every pull request, so each can be required. The two concurrency jobs run once per PostgreSQL version, so each reports two checks, and those are the names to enter:

- `web-availability-and-build`
- `authorization-and-command-suites`
- `command-concurrency (17)` and `command-concurrency (18)`
- `creation-concurrency (17)` and `creation-concurrency (18)`
- `billing-webhooks`
- `calendar-security`
- `npm-advisories`
- `swiftpm-advisories`
- `gradle-advisories`
- `android-build-and-signing`
- `android-emulator-tests`
- `package-regressions`
- `app-launch`

The three advisory jobs read live advisory databases, so a newly published advisory can fail a pull request that changed no dependency, which makes them less deterministic than the other checks. Clear one by updating the dependency (Dependabot proposes the update), or take the job off the required list while an update is pending.

Don't require `android-changes` or `ios-changes`. They are the gates described below and only decide whether the platform jobs run. Renaming a job breaks a required check that names it, so change job names only together with the ruleset.

## How the gating works

A workflow-level `on.pull_request.paths` filter keeps the whole workflow from starting, and GitHub then leaves its required checks pending as "Waiting for status to be reported" and blocks the merge. The Android and iOS workflows therefore have no `paths` filter. Each starts with a cheap gate job (`android-changes`, `ios-changes`) that runs on every pull request, and the expensive jobs depend on it:

- The gate checks out the pull request merge commit with `fetch-depth: 2` and runs `scripts/ci/changed-paths.sh`, which compares the merge commit with its first parent, the base branch tip, so it sees exactly what merging would change.
- The expensive jobs run when the gate reports a relevant change. Otherwise `if:` skips them. GitHub's [troubleshooting page for required status checks](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks) says a job skipped by a conditional reports "Success" and doesn't block merging, while a path-filtered workflow stays "Pending".
- The same page warns that a job skipped because a job it depends on failed may not block merging, which would let a broken gate pass the platform checks. The `if:` therefore also runs the job when the gate result isn't `success`, and `changed-paths.sh` treats a diff it can't compute as relevant. The gate fails open to running the work.
- A push to `main`, `workflow_dispatch` and any other event aren't pull requests, so everything runs.

What counts as relevant:

| Gate | Relevant paths |
| --- | --- |
| `android-changes` | `apps/android`, `packages/shared-config/date-time-fixtures.json`, `packages/shared-config/entitlements.json`, `scripts/ci/write-placeholder-google-services.sh` |
| `ios-changes` | `apps/mobile`, the same two shared fixtures, `scripts/ci/ios-package-regressions.sh`, `scripts/ci/check-ios-environment-keys.sh`, `scripts/ci/ios-app-launch.sh` |

Both lists also include the workflow's own file and `scripts/ci/changed-paths.sh`. Changing how a gate or job works runs that platform's jobs, because an edit that breaks them should fail on its own pull request. A docs-only or web-only pull request skips them and doesn't spend an emulator or macOS runner. A pull request skips a platform's jobs only if it touches none of that platform's paths, and the other platform's paths don't count. When you add a file a platform job reads, add its path to the gate's list in the workflow.

The other workflows run unconditionally on every pull request and need no gate.

## Updating a pinned action

Every `uses:` line in `.github/workflows` names a full 40-character commit SHA with the release it came from in a comment, such as `actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0`. A tag can be moved after the fact. A commit can't, so a compromised action repository can't change what the workflows run. This applies to first-party actions and to the Claude Code workflows too.

Dependabot's `github-actions` entry in `.github/dependabot.yml` opens a weekly pull request that raises the SHA and the comment together. To update by hand, resolve the tag to a commit. An annotated tag points to a tag object, so dereference it:

```sh
repo=actions/checkout; tag=v4.4.0
read -r type sha < <(gh api "repos/$repo/git/ref/tags/$tag" -q '.object.type + " " + .object.sha')
[ "$type" = tag ] && sha=$(gh api "repos/$repo/git/tags/$sha" -q .object.sha)
echo "$repo@$sha # $tag"
```

Replace every use of that action with the new SHA and comment, then run `actionlint`. The current pins stay on the major version each workflow already used, so a major upgrade is a deliberate change that needs a review of that action's release notes.

## Updating Gradle locks

`apps/android` locks dependency versions. `app/gradle.lockfile` pins the compile and runtime classpaths of the debug and release builds and of their unit-test and instrumented-test variants, and `buildscript-gradle.lockfile` pins the plugin classpath. Locking is `STRICT`: a build fails when one of those classpaths resolves to a version, or to a module, that the lockfile doesn't list. This is what makes `gradle-advisories` meaningful, because the scan reads the lockfile and the build can't drift from it. Build-tool configurations (lint, the Kotlin compiler, the test-device runner) aren't locked.

Regenerate both files after changing `app/build.gradle.kts` or the plugin versions in `build.gradle.kts`, and after merging a Dependabot Gradle pull request. Dependabot edits the build files and can't be relied on to regenerate the lockfiles, so a Gradle update pull request fails the Android jobs until you run this on its branch and commit the result:

```sh
cd apps/android
./gradlew --no-daemon --rerun-tasks -PallowUnsignedRelease=true \
  :app:assembleDebug :app:assembleDebugAndroidTest :app:testDebugUnitTest :app:assembleRelease \
  dependencies :app:dependencies --write-locks
git diff --stat -- '*.lockfile'
```

The tasks matter: a lock records only the configurations that get resolved. `--rerun-tasks` forces resolution of those that would otherwise be up to date, and `dependencies :app:dependencies` resolves the rest. `-PallowUnsignedRelease=true` only lets `assembleRelease` run without a keystore so its classpath resolves; the output isn't shipped. Run it with a JDK 21 and the Android SDK, as the Android jobs do. Review the lockfile diff like any dependency change.

Then confirm the locks are complete by building without `--write-locks`:

```sh
./gradlew --no-daemon -PallowUnsignedRelease=true :app:testDebugUnitTest :app:assembleDebugAndroidTest :app:assembleRelease
```

A failure naming a module that is "not part of the dependency lock state" means the regeneration missed something; see below.

If a build fails with "Resolved 'x' which is not part of the dependency lock state" for `debugAndroidTestRuntimeClasspath`, Gradle resolved the module through the Android plugin's version alignment and doesn't write such modules to the lock. Declare it as an `androidTestRuntimeOnly` dependency, as `kotlin-stdlib-common` is in `app/build.gradle.kts`, and regenerate.

The Gradle wrapper is pinned two ways: `distributionSha256Sum` in `gradle/wrapper/gradle-wrapper.properties` checks the downloaded distribution, and the Android jobs run `gradle/actions/wrapper-validation` to check `gradle-wrapper.jar` against Gradle's published checksums. When you upgrade Gradle, set `distributionSha256Sum` from the checksum published at `https://services.gradle.org/distributions/gradle-<version>-bin.zip.sha256`.
