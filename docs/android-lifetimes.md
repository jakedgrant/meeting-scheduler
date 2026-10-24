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

The original F13 delivery added these six tests to CI's `:app:testDebugUnitTest` step. Its local validation was limited by the toolchain available at that time. The F12/F14 follow-up now runs 55 JVM tests, builds both Android APKs and exercises a fresh Android 36 emulator; see the [current evidence](architecture-remediation-evidence-2026-10-23/f12-f14-f22/android.md).

## Scope of the original F13 delivery (historical)

- **Session scope (F12).** This remained open in the original F13 delivery. The subsequent F12 work establishes account/generation boundaries, cancels old profile/screen work, resets poll/billing/calendar state and fences provider results and cleanup. The authenticated Compose subtree is recreated at each boundary; account retry records remain durable. [Current contract](session-lifecycle.md).
- **ViewModels.** Screens still call services directly from `rememberCoroutineScope`, and requests are cancelled when a screen leaves composition. Moving screen state into ViewModels (`viewModelScope`) so work survives recreation is the remaining F13 step 2, and is easier now that the container provides dependencies.
- **Auth deep links (F14).** These were incomplete in F13. The follow-up now routes cold and warm intents through an application-owned PKCE router, with persisted attempt ownership and distinct auth/calendar routes. [Callback configuration and remaining provider actions](android-auth-callbacks.md).
- **Behaviour checks on a device.** The original F13 delivery did not use an emulator. The F12/F14 follow-up verifies Activity recreation, cold/warm callbacks and route separation on a newly reserved offline emulator. Real sign-in/sign-out across providers still requires an approved test environment/account; local runtime evidence does not establish it.
