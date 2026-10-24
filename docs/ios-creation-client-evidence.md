# iOS transactional poll creation (F05 + F09)

`CreatePollView` submits the complete title, location, description, timezone, deadline and options through `create_poll(operation_id, payload)`. The previous poll insert, later option insert and optional quota preflight are removed. The server returns the poll's premium state, participant limit, generated share code, time options, redeemed pass and effective entitlement. `PollService` installs the returned poll and options, deduplicates a replay, and rejects an older list response that could erase that result.

The event-pass switch is explicit and off by default. It requests the oldest eligible pass. Its explanation states that an active Pro or Team subscription takes priority and preserves the pass. No client premium boolean grants creation access. Capacity failures from `join_poll` have a user-readable participant-limit message.

Before dispatch, `PollCreationEditor` writes the exact request envelope to an atomic file in Application Support, keyed by account UUID. A failed or lost transport reply keeps the request locked for retry. Closing the form or restarting the app restores the same operation ID and payload. A definite quota, pass or payload rejection retains an editable draft; an unchanged retry keeps its ID and an edited draft starts a new operation. SQLSTATE `22000` keeps the request locked because the server may already hold another committed payload for that ID. A completed editor rejects another queued submit.

Storage-write failure prevents dispatch. An unreadable saved file blocks a second creation and directs the user to check My Polls and retry loading the saved request. Account transitions clear visible editor state and invalidate pending completions without deleting the original account's recovery envelope. The service uses the existing account generation, including A-to-B-to-A transitions, before caching or publishing results.

Options and deadlines encode explicit ISO 8601 UTC instants. The pinned Supabase Swift encoder otherwise omits the zone in its Date output; the actual SDK transport test caught that behavior. An editable restored draft converts and labels times in the current system timezone. An unresolved retry sends its saved payload unchanged. Broader all-day/calendar-date semantics remain F21 work.

## Verified source and results

Source commit: `ec31397128593352532e5e47441faf9ca8242993`. Xcode 27.1 (`27A9269`), Swift 6.4, iPhone 17 Pro on iOS 27.0. Committed dependency lockfiles are unchanged; the isolated dependency copies contain Supabase Swift 2.39.0 and RevenueCat 5.97.0.

The package passed `build-for-testing` and **71 tests with zero failures**: 23 persistence-provider, nine lifecycle, eleven availability-editor, ten availability-transport, eleven creation-editor, six creation-transport and the existing baseline test. The tracked app wrapper also builds against a generic simulator destination with code signing disabled.

The eleven creation-editor tests cover invalid options before dispatch, lost reply and file-backed restart recovery, immutable unresolved payloads, definite rejection and edited retries, changed-operation rejection, queued submission after success, storage failure, corrupt storage, per-account persistence and late success/error after account transitions. The six creation-transport tests use the actual pinned Supabase client with URLProtocol and an `.invalid` hostname. They verify the RPC path, complete body and explicit nulls, UTC instants, absent client authority fields, SQL error mapping, replay deduplication, authoritative cached options/poll state, capacity messaging, A-to-B-to-A fencing and rejection of an older list result.

Local commands used the generated package workspace and isolated build/dependency directories:

```bash
xcodebuild -workspace "$repo/apps/mobile/.swiftpm/xcode/package.xcworkspace" \
  -scheme MeetingScheduler-Package -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-f05-ios-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-f05-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO build-for-testing

xcodebuild -workspace "$repo/apps/mobile/.swiftpm/xcode/package.xcworkspace" \
  -scheme MeetingScheduler-Package -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-f05-ios-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-f05-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'platform=iOS Simulator,id=526D05E1-3CF3-45B5-A6B2-F3034FA48A72' \
  CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO -only-testing:MeetingSchedulerTests \
  -resultBundlePath /private/tmp/meeting-scheduler-f05-ios-ec31397-tests.xcresult test-without-building

xcodebuild -project "$repo/apps/mobile/MeetingScheduler/MeetingScheduler.xcodeproj" \
  -scheme MeetingScheduler -configuration Debug \
  -derivedDataPath /private/tmp/meeting-scheduler-f05-ios-wrapper-derived \
  -clonedSourcePackagesDirPath /private/tmp/meeting-scheduler-f05-ios-packages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Here `repo=/private/tmp/meeting-scheduler-f05-f09-ios`. The simulator was newly created for this work under coordinator approval. Its ID is evidence of this run; future local runs need their own reservation and device. It was shut down and deleted after the final 71-test run and wrapper build; both cleanup commands succeeded. No existing device, localhost server, hosted database or provider was used.

Raw logs are `/private/tmp/meeting-scheduler-f05-ios-ec31397-build.log`, `/private/tmp/meeting-scheduler-f05-ios-ec31397-tests.log` and `/private/tmp/meeting-scheduler-f05-ios-ec31397-wrapper.log`; the xcresult path is in the command above. `git diff --check` and both committed lockfile checks passed. The existing iOS CI script repeats the package regressions on a disposable runner.

These checks cover editor state, production service/cache logic, actual SDK transport and wrapper compilation. A mounted signed-in UI journey, hosted PostgREST validation and a distribution-signed archive remain prelaunch work.
