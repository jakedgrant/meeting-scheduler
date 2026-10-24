# F12/F14/F22 account/session lifecycle evidence

This tranche starts from verified main `d51f45a366cbd4a9ecd30e774d8b50441a938894`. It completes remaining account/session isolation, Android auth callback routing and production web auth lifecycle regression coverage. The [session contract](../../session-lifecycle.md) was recorded in `483ca17a14107d38ce0608ea33f315b776d3b552` before the three platform owners began concurrent implementation.

## Baseline verification

The coordinator fetched remote main and used `git merge-base --is-ancestor 6148a12edfa66d11e293e0d0bea27896091b15c9 origin/main`. PR #71's exact head is a merge parent of `d51f45a`; `git diff --quiet 6148a12 d51f45a` succeeds. GitHub metadata and all six successful workflow runs were inspected for that exact head. #71 delivers F05/F09 across backend and all clients; its test counts remain [baseline evidence](../f05-f09/README.md).

Local main was fast-forwarded after a complete backup of its ignored iOS app wrapper to `/private/tmp/meeting-scheduler-original-ios-wrapper-20261024`. All 14 conflicting files matched tracked main byte-for-byte. Existing `.claude/worktrees/` and local `packages/shared-config/product-ids.json` were preserved. Implementation is in isolated clones. The previous unused managed worktree still exists on disk at `5b9c5e4` and is unattached to this chat; it was not reused or changed.

## Ownership and validation

Web owns auth/profile, subscription, RevenueCat, calendar, poll and screen integration plus F22 production regression tests. Android owns application auth/session integration and F14 SDK/manifest/cold/warm routing. iOS audits and fixes remaining auth/provider/preference boundaries while preserving its merged cache and command systems. Coordinator owns shared scripts/workflows, integration and this index. An independent final combined-tree review follows platform completion. After an account usage interruption, the owner directed the remaining agents to run one at a time: web, Android, then iOS. No implementation agents run concurrently during this continuation.

The preserved backend at contract commit `483ca17` passed `npm run test:database` (142 checks), `npm run test:billing:edge` (15), `npm run test:calendar:edge` (23), frozen checks for seven entry points and billing lint (eight files). No backend or migration changes are planned. These are deterministic in-process/offline regressions and did not contact a hosted project or provider.

## Web integration checkpoint

Web source/test commit `c5b6538e26f066515e2cdaf95db9ddc700181238` was integrated as `d15fad2`; evidence-only `00b6d59` was integrated as `c1d83fb`. The coordinator reran all 111 web tests on the integration tree (55 lifecycle/SDK plus 56 existing regressions), type checking (zero errors/five existing warnings) and production client/SSR build. [Platform evidence](web.md) records covered races and live-provider limits. [Integrated test output](web-results.txt). A subsequent coordinator dispatch follow-up (`b1e311a`, test follow-up `d0a7e82`) brings the current integrated count to **113** (57 lifecycle/SDK plus 56 existing). It prevents a command owned by A from waiting for SDK credentials and accidentally dispatching under B. Real SDK regressions cover both creation and calendar disconnect; the original creation path fails the new test. Type check and production build also pass.

## Runtime reservations

| Runtime | Approval | Cleanup |
| --- | --- | --- |
| iOS | Fresh iPhone 17 Pro / iOS 27.0, `0EC9E5B6-47CE-4D21-A938-3C00075E1D02`; create/boot/install/test, 40 minutes from creation; package tests and brief wrapper lifecycle smoke only | Coordinator shut down and deleted this device after the interruption; a fresh reservation/device is required for subsequent tests |
| Android | New isolated SDK `/private/tmp/session-android-sdk`, AVD `session-f12-f14` under `/private/tmp/session-android-avd`, ports 5580/5581 after unused-port check; headless deterministic callback/recreation checks; 45 minutes from start | Coordinator stopped `emulator-5580` after the interruption (`emu kill`: OK). Downloaded image and named AVD remain as stopped test artifacts; future checks require a fresh reservation/device |
| Android continuation | Fresh AVD `session-f12-f14-resume` under `/private/tmp/session-android-avd-resume`, ports 5582/5583 after unused-port check; 45 minutes from creation; headless/offline deterministic checks | Android owner must kill only `emulator-5582` and delete this new AVD after validation |
| Web | In-process fixtures, type check and production build; no listening server | No server to stop |

The first reservations expired during the interruption. At approximately 07:54 UTC October 24 the coordinator stopped the stalled task-owned Gradle jobs and named emulator, and shut down/deleted the named simulator. Existing user runtimes were left intact. Earlier runtime reservations and device IDs were not reused. Workers must request coordinator approval before any further simulator/emulator/local server/Supabase/Docker/existing-service use.

## Provider and hosted boundary

No approved provider account/environment was supplied at implementation start. Source and deterministic validation proceed independently. Exact redirect/provider configuration and live owner actions are recorded in platform evidence. No merge, deployment, hosted allowlist change or real development/beta data mutation is authorized. F21/F16 dates/calendar and F19 → F18 → F20 reads/realtime remain queued.
