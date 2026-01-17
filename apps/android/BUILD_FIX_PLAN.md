# Android Build Fix Plan

## Overview
This plan addresses ~60 code-level compilation errors after updating to:
- Kotlin 2.2.20
- Supabase BOM 3.3.0
- Ktor 3.2.3
- Navigation Compose 2.8.5

---

## Issue Categories

### 1. Missing `toJavaInstant` Import (17 occurrences)
**Problem:** `toJavaInstant` extension function is not imported.
**Solution:** Add `import kotlinx.datetime.toJavaInstant` to affected files.

**Files to fix:**
- [ ] `ui/PollDetailView.kt` (lines 31, 465, 471, 472, 540, 575, 576, 746, 757, 758, 793, 801, 802)
- [ ] `ui/PollListView.kt` (lines 22, 279)
- [ ] `ui/TimeOptionResponsesView.kt` (lines 23, 128, 140, 141)

---

### 2. `TimeZone.System` Reference Error (4 occurrences)
**Problem:** `TimeZone.System` should be `TimeZone.currentSystemDefault()` in kotlinx-datetime.
**Solution:** Replace `TimeZone.System` with `TimeZone.currentSystemDefault()`.

**Files to fix:**
- [ ] `services/AuthService.kt` (line 188)
- [ ] `ui/CreatePollView.kt` (lines 23, 44, 45)

---

### 3. Supabase Auth API Changes (7 occurrences)
**Problem:** Supabase 3.x changed auth API - `SessionStatus`, `idToken`, `session` references.
**Solution:** Update to new Supabase auth API patterns.

**Files to fix:**
- [ ] `services/AuthService.kt`:
  - Line 68: `SessionStatus` - use `AuthStatus` instead
  - Line 70: `SessionStatus` - use `AuthStatus` instead
  - Lines 71-72: `session` property access changed
  - Line 78: `SessionStatus` - use `AuthStatus` instead
  - Lines 109, 116: `idToken` - use `IdToken` builder pattern

---

### 4. Supabase Postgrest API Changes (6 occurrences)
**Problem:** Postgrest DSL changed - `from`, `filter`, `eq` syntax updated.
**Solution:** Update to new Postgrest query builder syntax.

**Files to fix:**
- [ ] `services/CalendarService.kt`:
  - Lines 132-135: Update `from().filter { eq() }` syntax
  - Lines 151-154: Update `from().filter { eq() }` syntax

---

### 5. Supabase RPC/Query API Changes (6 occurrences)
**Problem:** `rpc()` and `order()` function signatures changed.
**Solution:** Update function calls to match new API.

**Files to fix:**
- [ ] `services/PollService.kt`:
  - Line 50: `rpc()` needs type parameter and parameters
  - Line 87: `rpc()` receiver type mismatch
  - Line 137: `order()` parameter changed from `ascending` to `order`
  - Line 224: `select()` expects `Columns` type, not `String`

---

### 6. Navigation Compose API Changes (6 occurrences)
**Problem:** `composable` function import/usage changed in Navigation 2.8.x.
**Solution:** Update import and usage pattern for `composable`.

**Files to fix:**
- [ ] `ui/MainTabView.kt`:
  - Lines 61-62: Fix `composable` reference and @Composable context
  - Lines 75-76: Fix `composable` reference and @Composable context
  - Lines 82-83: Fix `composable` reference and @Composable context

---

### 7. Apple Sign-In References (2 occurrences)
**Problem:** `Apple` provider referenced but not available on Android.
**Solution:** Remove or conditionally compile Apple Sign-In code for Android.

**Files to fix:**
- [ ] `ui/AuthView.kt`:
  - Line 10: Remove `Apple` import
  - Line 159: Remove or hide Apple Sign-In button

---

### 8. RevenueCat API Changes (1 occurrence)
**Problem:** `purchase()` expects `PurchaseParams`, not `Package`.
**Solution:** Wrap package in `PurchaseParams`.

**Files to fix:**
- [ ] `services/PurchaseService.kt`:
  - Line 112: Use `PurchaseParams.Builder(activity, package).build()`

---

### 9. Type Mismatches (5+ occurrences)
**Problem:** Various `List<String>` vs `String` type mismatches.
**Solution:** Fix type declarations or convert between types.

**Files to fix:**
- [ ] `ui/PollDetailView.kt`:
  - Line 102: Type mismatch
  - Line 365: Type mismatch
- [ ] `ui/TimeOptionResponsesView.kt`:
  - Line 84: Type mismatch
- [ ] `ui/CreatePollView.kt`:
  - Line 94: `List<Triple<...>>` vs `List<TimeOptionInput>`

---

### 10. Missing References (3 occurrences)
**Problem:** Various unresolved references.
**Solution:** Add missing types/functions or update code.

**Files to fix:**
- [ ] `ui/PollDetailView.kt`:
  - Line 116: `CalendarSource` unresolved
  - Line 354: `submitAvailability` unresolved
- [ ] `ui/PollListView.kt`:
  - Line 57: `canCreatePoll` unresolved
- [ ] `ui/PaywallView.kt`:
  - Line 128: `Infinity` unresolved (use `Float.POSITIVE_INFINITY`)

---

## Execution Order

1. **Phase 1: Simple Fixes** (imports and renames)
   - Add `toJavaInstant` imports
   - Fix `TimeZone.System` → `TimeZone.currentSystemDefault()`
   - Fix `Infinity` → `Float.POSITIVE_INFINITY`
   - Remove Apple Sign-In references

2. **Phase 2: Supabase Auth Updates**
   - Update `AuthService.kt` for new auth API

3. **Phase 3: Supabase Postgrest Updates**
   - Update `CalendarService.kt` for new query syntax
   - Update `PollService.kt` for new RPC and query syntax

4. **Phase 4: Navigation Compose Updates**
   - Update `MainTabView.kt` for new navigation API

5. **Phase 5: Type Fixes**
   - Fix type mismatches in views
   - Update `PurchaseService.kt` for RevenueCat API

6. **Phase 6: Missing References**
   - Add or fix `CalendarSource`, `submitAvailability`, `canCreatePoll`

---

## Progress Tracking

| Phase | Status | Files Fixed |
|-------|--------|-------------|
| Phase 1 | Not Started | 0/7 |
| Phase 2 | Not Started | 0/1 |
| Phase 3 | Not Started | 0/2 |
| Phase 4 | Not Started | 0/1 |
| Phase 5 | Not Started | 0/4 |
| Phase 6 | Not Started | 0/3 |

---

## Notes
- Always run `./gradlew compileDebugKotlin` after each phase to verify fixes
- Some fixes may reveal additional hidden errors
- Use `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"` when running Gradle
