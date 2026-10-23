# iOS transactional availability client

The detail screen now loads the participant's saved version with `get_availability` and submits the complete draft plus comment through one `save_availability` command. The returned row IDs, statuses, notes, comment and version become the saved state. A failed request leaves the draft and previous saved snapshot intact and shows a retry action. An unchanged retry retains its request UUID; editing the draft creates a new operation.

A version conflict blocks further saves until the user loads the latest saved responses. That action updates the baseline/version while retaining the draft for review; the next save uses a new request UUID and the loaded version. Initial response loading must succeed before controls are editable, so a retry cannot accidentally replace an unknown response set with an empty draft. Notes loaded from the server survive status/comment edits.

The organizer selects an option through `finalize_poll`, then displays the authoritative returned poll, including its closed status. Finalization/join/status failures appear in the screen even when the organizer has no participant membership. Member joins use the idempotent `join_poll` command. The previous per-option response writes, separate comment writes and selected-time pair writes have been removed from the native protocol and service.

The editor supports guest-capability command arguments and tests them. Native navigation still requires sign-in; this change does not add a signed-out native guest journey. Web owns that user flow.

The detail screen keys loading and visible state by both account and poll. The editor's generation prevents a late load/save from restoring the previous account after reset, and the view checks its captured identity before applying command or calendar results. Detached view actions retain no authority to publish after the view's identity changes.

## Verification

Xcode 27.1 (27A9269), Swift 6.4; pinned Supabase 2.39.0 / RevenueCat 5.97.0 from isolated local dependency copies.

- Full package `build-for-testing` passed.
- The initial standalone client package run passed **15 tests**: ten editor scenarios, four actual Supabase-client transport tests, and one pre-existing placeholder.
- Transport tests intercept an ephemeral URLSession with URLProtocol using an `.invalid` hostname. No localhost server, hosted Supabase account or provider API is used.
- Editor tests cover failed save, lost reply and retry, changed draft/new request ID, version conflict and explicit reload, failed initial read, closed poll, late load/save after account reset, edits during an in-flight save, retained notes and guest arguments.
- Transport tests check the actual RPC path/body, complete empty replacement set, explicit null comment, expected version/request UUID/guest capability, persisted response decoding, SQL error mapping, and authoritative finalization by option identity.

The client has now been merged with coordinator head `0ce4bc5a1f3ace656ef8473fa4be6acd2feedf83`, including the corrected SwiftData PR, backend/web/Android changes and iOS CI. The combined package run passed **54 tests**, zero failures: 23 provider tests, nine lifecycle tests, eleven availability editor tests, ten actual SDK transport tests and the existing placeholder. The final combined run finished October 23, 2026 at 02:50 Chicago time. `git diff --check` passed.

Command methods now reject results after an account transition or cancellation. A save invalidates detail before dispatch and after success or failure, since a lost reply may follow a committed write. A participant-only result updates the editor's saved snapshot and does not renew cached detail for other participants. Finalization invalidates detail, caches the returned poll and updates list state; an older in-flight list cannot restore its active status. Extra integration regressions cover those cache boundaries, a command completing after account change, a late conflict after editor reset, and idempotent member-join transport.

Raw local evidence is in `/private/tmp/meeting-scheduler-ios-test-integrated-b3.log` and `/private/tmp/meeting-scheduler-ios-tests-integrated-b3.xcresult`; the committed CI workflow reruns the package suite on future PR heads. These are service/editor/transport tests; a signed-in UI or hosted PostgREST journey remains prelaunch work.
