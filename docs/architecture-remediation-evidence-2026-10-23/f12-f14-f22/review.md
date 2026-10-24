# Independent combined-tree review

A fresh reviewer inspected `f3df14f3328bfd051b51de61465e6d8c4b3ec78f` against verified main `d51f45a366cbd4a9ecd30e774d8b50441a938894` in a separate clone. The review covered production services/composition, SDK transport and persistence, callback ownership, provider ordering, account recovery, workflow integration and preserved backend contracts.

## Initial findings

| Priority | Demonstrated gap | Required correction |
| --- | --- | --- |
| P1 | Android gateway chose the logout credential after waiting for its dispatcher/mutation lock. A queued A logout cleared B and revoked `Bearer token-B` in a production gateway/pinned-SDK probe. | Capture the initiating session before suspension, conditionally clear only its matching lineage, and remotely revoke only the captured local session. |
| P2 | Android direct poll reads and profile updates omitted the captured request credential. Production `loadPoll` sent B's token while app ownership was A. Calendar conflict loading also selected credentials after device-calendar suspension. | Pin every account-owned request at initiation and guard resumed device-calendar work before dispatch. |
| P2 | Android classified fresh same-account authentication as refresh. Production handler kept generation `1 → 1` and retained the old callback intent; cold restoration compared only account UUID. | Include session lineage in boundary and persisted callback ownership, retaining generation only for ordinary refresh within that lineage. |

The reviewer independently passed **137 web tests and 142 database checks**. Native path hashes and retained validation matched the tested sources. No additional actionable web/iOS or CI finding was identified. Backend/shared configuration and dependency locks were unchanged. No repository source was modified during review, and no shared runtime or provider was used.

Probe artifacts are `/private/tmp/ReviewSessionProbe.java`, `/private/tmp/ReviewDispatchProbe.kt` and `/private/tmp/review-dispatch-probe.log`. They ran production Android code and the pinned SDK with in-process injected dependencies. These initial findings were sent to the Android owner for correction before publication. Final remediation and re-review are recorded below when complete.

## Final independent re-review

The reviewer cleared combined source **`7ec897ad451980d15333e59752dd3d300c76fed0`**: **no actionable findings remain**, and all three original findings are resolved. Android correction `c0bd812` integrates as `6f57c00`; its subtree is `198637e3840b3d9fa02493cf4a9161e5c58ace48`.

Independent production-code probes now report:

- Queued A logout retains B and revokes only A: `remaining=token-B; revoked=[Bearer token-A]`.
- Direct poll reads retain A's captured credential with SDK B installed: `Authorization=[Bearer token-A]`.
- Fresh same-account authentication advances generation `1 → 2` and invalidates the old callback. Same-lineage refresh and cold callback ownership pass the production SDK regressions.

The reviewer independently replayed **75 JVM tests, all passing**. Log: `/private/tmp/independent-android-review-rerun-final.log`; corrected probes: `/private/tmp/review-dispatch-probe-final.log`. Initial manual classpath/working-directory errors were harness issues and are excluded from passing evidence. A disposal probe also passed: owned logout completed its original credential cleanup, and `jobs.toList().forEach` prevented completion callbacks from mutating the disposal iteration.

`AccountPostgrest` supplies one captured Authorization value through the pinned SDK query implementation, shares existing transport/configuration, and creates no client, engine or listener. Its internal SDK boundary and upgrade check are documented. Web/iOS source and backend contracts did not change after the full review; those conclusions stand. The native build and three offline instrumentation results match the final evidence. No source edits or shared resources were used by the reviewer.

Documentation-only publication commits may follow this source checkpoint. The source manifest identifies the exact reviewed/tested path trees. Hosted redirect acceptance/query preservation and real auth/calendar/RevenueCat journeys remain the documented owner checks. PR publication and final CI are separate delivery gates.
