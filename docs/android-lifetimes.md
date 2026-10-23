# Android service lifetimes

This document records who owns the Android app's services and coroutine scopes. It addresses finding F13 in the [architecture review](architecture-review-2026-10-21.md#f13-android-singletons-retain-an-activity-and-its-cancelled-scope).

## Problem

`MainActivity.onCreate` passed `this` and its `lifecycleScope` to `AuthService.getInstance`, `PollService.getInstance`, `CalendarService.getInstance`, and `PurchaseService.getInstance`. Each factory cached the first instance in a companion object and returned it to every later Activity. `MainActivity` declares no `configChanges`, so the first rotation, dark-mode switch, or system-initiated recreation destroyed that Activity and cancelled its `lifecycleScope`. The consequences:

- `AuthService`'s `sessionStatus` collector ran in the cancelled scope and stopped for the rest of the process. Later sign-ins, sign-outs, and token expiry no longer updated `currentUser`, the profile, or the RevenueCat identity. Calendar preference loading and initial billing loads were also tied to that scope.
- `AuthService` held the first Activity as its `Context`, which kept the destroyed Activity alive for the life of the process. (The Context was never actually used.)
- `AuthService` reached billing through the static `PurchaseService.instance`.

## Ownership after this change

| Owner | Lifetime | Holds |
| --- | --- | --- |
| `MeetingSchedulerApplication` (registered in the manifest) | Process | One `AppContainer`, created in `Application.onCreate` |
| `AppContainer` | Process | `applicationScope`, `PurchaseService`, `AuthService`, `PollService`, `CalendarService` |
| `applicationScope` = `SupervisorJob() + Dispatchers.Main.immediate` | Process; never cancelled | The auth session listener, the initial session, profile and billing loads, and calendar preference loading |
| `MainActivity.lifecycleScope` | One Activity instance | Work that belongs to the visible Activity: `onResume` and calendar-callback connection refreshes |
| `rememberCoroutineScope()` in screens (unchanged) | One composition | User-triggered requests such as loading, saving, or purchasing |

Rules:

- Services take the `Application`, never an Activity, `LifecycleOwner`, or Activity `Context`. `CalendarService`'s constructor now requires `Application`. Calls that need an Activity, such as `PurchaseService.purchase(activity, …)`, receive it as a call argument and do not store it.
- Only `AppContainer` constructs services. No service has a companion-cached instance.
- `AuthService` receives billing through the small `BillingIdentity` interface, which `PurchaseService` implements. The container creates `PurchaseService` first, so `Purchases.configure` runs in `Application.onCreate`, as RevenueCat recommends, before auth can log a user in.
- `PollService` no longer accepts a scope it never used.

Compose reads service state through `mutableStateOf` snapshot state, as before. That state is lifecycle-agnostic and does not reference an Activity, so it needs no additional collection API.

## Tests

`app/src/test/.../ServiceLifetimeTest.kt` runs on the JVM, with no device or emulator:

- Service constructors accept no `Activity`, no `LifecycleOwner`, and no `Context` other than `Application`.
- Services have no companion object and no static field holding a service, `Context`, `CoroutineScope`, or `LifecycleOwner`.
- Only `AppContainer.kt` constructs services (source scan of `src/main/kotlin`).
- The manifest registers `.MeetingSchedulerApplication`.
- A collector in the application scope keeps receiving events after an "Activity" scope is cancelled, and a failed child does not cancel the application scope.

The tests run in CI's `:app:testDebugUnitTest` step. That step comes from the `Android` workflow added with F26 (`.github/workflows/android.yml`), which is not on this branch. They were not run locally, because this workstation has no Gradle-compatible JDK or Android SDK 36 (see `docs/android-release-signing.md`).

## Not covered here (follow-ups)

- **Session scope (F12).** The listener lives in the application scope, and account changes are not yet a separate, cancellable session scope. `CalendarService` already guards results with a connection generation. A per-session scope with poll, billing, and calendar state reset should follow the F12 contract.
- **ViewModels.** Screens still call services directly from `rememberCoroutineScope`, and requests are cancelled when a screen leaves composition. Moving screen state into ViewModels (`viewModelScope`) so work survives recreation is the remaining F13 step 2, and is easier now that the container provides dependencies.
- **Auth deep links (F14).** `handleDeepLink` is still empty, and `MainActivity` doesn't process auth intents.
- **Behaviour checks on a device.** Rotation, background/foreground, and sign-out after recreation were not exercised. They need an emulator reservation (see the report).
