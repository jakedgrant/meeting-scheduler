# Web guest access and availability saves

The poll page saves availability and the participant comment with one `save_availability` command. The same path serves signed-in members and guests. It replaces the per-option writes and separate comment update that could leave a partial save.

This adapter requires the F03 participant-access, F04 membership-integrity, and F06/F10 response-command migrations. Ship the completed backend stack with this web build before public launch. The app has not been publicly released, so the adapter does not fall back to direct writes when a command is missing. A missing command leaves the draft intact and displays an actionable error.

## Guest joins and reloads

`joinPoll` generates a 32-byte token with `crypto.getRandomValues` before calling `join_poll_as_guest`. The pending token is kept per poll in memory and, when possible, in browser storage. A transport failure keeps that token, so retrying a join returns the existing participant through F04's idempotency contract. A working storage implementation also keeps the pending token across a page reload.

After a successful join, the participant ID and capability are kept per poll in memory before attempting browser persistence. `loadPoll` checks that memory map first. The immediate join-to-load flow and later navigation in the same session therefore work when storage throws or is unavailable. A full browser refresh still loses an unpersisted capability. Invalid or revoked capabilities are removed and the page offers to join again.

The token is sent only to capability-aware RPCs. It is never rendered, and transport errors from these operations are not logged with their request payloads. Signed-in joins use the idempotent `join_poll` command.

## Drafts, retries, and conflicts

`get_availability` supplies the saved response set, comment, and participant version. The page uses `createAvailabilityEditor` to keep that snapshot separate from the editable draft. A failed initial read disables editing and offers a retry, so a failed read cannot become an empty full-set replacement.

A save sends the complete response set, existing notes, comment, saved version, and a generated request ID. That ID remains attached to the unchanged draft after a network or server failure. Retry sends the same payload and ID, including after a response was lost following a commit. Editing the failed draft starts a new logical operation with a new ID.

The page applies only the returned persisted snapshot and shows success only after that command returns. It does not reload the detail to infer whether saving worked. Errors keep the draft visible. Refreshes and Realtime participant updates cannot replace an unsaved draft. Empty returned response sets clear the local saved rows rather than retaining earlier responses.

A `PT409` conflict blocks saving until the user chooses **Reload saved version and keep my draft**. The editor loads the latest snapshot and version, keeps the draft, and shows the saved responses for comparison. The user can then explicitly save the draft with a new request ID. A failed reload keeps the conflict blocked. The adapter never silently retries with last-write-wins.

Guests see the same availability buttons and comment editor as members. Closed polls and elapsed response deadlines hide those controls. Organizers select the final option through `finalize_poll`; the returned poll row supplies the exact selected interval and closed status. Account transitions clear the current detail and editor, and stale reads or save completions cannot restore the preceding account's state.

## Verification

Install the web dependencies, then run from the repository root:

```bash
npm --prefix apps/web ci --ignore-scripts --no-audit --no-fund
node --test tests/web-guest-capability.test.mjs tests/web-availability.test.mjs
npm --prefix apps/web run check
VITE_SUPABASE_URL=https://example.supabase.co VITE_SUPABASE_ANON_KEY=test-public-key npm --prefix apps/web run build -- --configLoader runner
```

The 17 checks comprise four capability-helper tests and 13 integration tests. The integration suite bundles the actual poll store, editor, and Svelte page. It uses real Svelte stores and server rendering, with an in-process fake transport in place of Supabase. It opens no port and makes no hosted request.

The suite covers unavailable storage through join and reload, per-poll separation, a lost join response, pending-token persistence across module reloads, failed or lost saves and safe retries for guests and members, explicit conflict resolution, failed conflict reloads, saved snapshot application, note preservation, empty snapshots, revoked capabilities, member joins, finalization, closed and expired UI, initial-read errors, and account changes during a save. Rendered page assertions check guest availability controls, retry messages, conflict controls, and success feedback.

On October 23, 2026, all 17 checks passed. `svelte-check` reported zero errors and five existing warnings outside the changed page. The client and server production build passed; it retained the existing large-chunk warning and adapter-auto deployment-target notice. Validation used read-only dependency symlinks with all generated output in the isolated clone and Vite's runner config loader. No browser journey, hosted PostgREST behavior, or database authorization is established by these web tests; the backend suites cover the command implementation separately.
