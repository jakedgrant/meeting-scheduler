# Tested source manifest

Combined source snapshot before final review: `9eb4081f0bf6ecd4bf7d3e56b25d5408b935ac44`. Documentation-only commits may follow; these path hashes and comparisons identify the tested implementation.

| Scope | Tested source | Integrated path tree |
| --- | --- | --- |
| `apps/web` | `f82b7e21119f375aa63bc10f809aff91636459f3` | `4079ba6f9e12da29731847b4629d56cf7789ef38` |
| `apps/mobile` | `ed8c8a4af92cdff40c6c7fd615b390a9a96452d9` | `5eb4a4e177b4f745d53983a3d6802803196ee4d2` |
| `apps/android` | `d60192c9cd11728b254d7fabe28aa7bbcd5454f5` | `b98a5925631adeeb4bba902637afcbc3825a12ad` |
| `supabase` | `d51f45a366cbd4a9ecd30e774d8b50441a938894` | `fef9fec8126ba64e3f17833a3d6caf19119591b1` |

The coordinator verified:

```bash
git diff --quiet f82b7e2 HEAD -- apps/web tests/web-*.test.mjs
git diff --quiet ed8c8a4 HEAD -- apps/mobile
git diff --quiet d60192c HEAD -- apps/android
git diff --quiet d51f45a HEAD -- supabase packages/shared-config
git diff --check
```

The root web regression files are also identical to their tested source. No dependency lock or backend command/billing/authorization contract changed. The evidence index links exact platform commands, results, cleanup and remaining hosted owner actions.
