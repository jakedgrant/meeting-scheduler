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
