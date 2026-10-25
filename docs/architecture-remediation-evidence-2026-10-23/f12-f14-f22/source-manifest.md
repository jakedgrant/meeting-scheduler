# Tested source manifest

Current tested implementation source: `90e4db3965cb9722255e3d52343b426fc2ca34a0`. The earlier independent review covers `7ec897a`; the later owner-requested iOS refactor was implemented and reviewed directly by the coordinator without subagents, as recorded in [comment evidence](review-comments.md). Documentation-only commits may follow; these path hashes and comparisons identify the tested implementation.

| Scope | Tested source | Integrated path tree |
| --- | --- | --- |
| `apps/web` | `f82b7e21119f375aa63bc10f809aff91636459f3` | `4079ba6f9e12da29731847b4629d56cf7789ef38` |
| `apps/mobile` | `90e4db3965cb9722255e3d52343b426fc2ca34a0` | `928878beebefd3b2149e92973f7ee085e41e7acf` |
| `apps/android` | `c0bd8126d7ae9e59c2ebcc0055e20162688d26ed` | `198637e3840b3d9fa02493cf4a9161e5c58ace48` |
| `supabase` | `d51f45a366cbd4a9ecd30e774d8b50441a938894` | `fef9fec8126ba64e3f17833a3d6caf19119591b1` |

The coordinator verified:

```bash
git diff --quiet f82b7e2 HEAD -- apps/web tests/web-*.test.mjs
git diff --quiet 90e4db3 HEAD -- apps/mobile
git diff --quiet c0bd812 HEAD -- apps/android
git diff --quiet d51f45a HEAD -- supabase packages/shared-config
git diff --check
```

The root web regression files are also identical to their tested source. No dependency lock or backend command/billing/authorization contract changed. The evidence index links exact platform commands, results, cleanup and remaining hosted owner actions.
