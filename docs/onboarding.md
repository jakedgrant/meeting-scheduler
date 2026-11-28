# Onboarding

After an account's first sign-in, iOS and Android show two optional steps before the Meets tab: a display name, then calendar connections. Both steps can be skipped, and the flow never blocks the app.

Migration: [`20261127000000_profile_onboarding.sql`](../supabase/migrations/20261127000000_profile_onboarding.sql). Test: `tests/profile-onboarding.test.mjs`.

## When it shows

`profiles.onboarding_completed_at` records completion per account, so a reinstall or a second device doesn't show the flow again. `get_my_profile` returns it with the rest of the owner's row; the Data API column grants are unchanged, so poll peers can't read it. `complete_onboarding()` stamps the caller's row with the server time once and returns the stored value, so clients can retry it.

The migration marks every existing account complete as of its `created_at`, without touching `updated_at`. Only accounts created after it is applied see onboarding.

Each client decides with `onboardingStatus` on its `AuthService`:

| State | When | Shows |
| --- | --- | --- |
| Not required | The server profile has a completion, or this device recorded one for the account, or the profile couldn't be loaded | The tabs |
| Required | The server profile loaded without a completion and this device has none | Onboarding |
| Undetermined | Neither of the above yet | The loading view |

The cached iOS profile doesn't decide this, because it may predate a completion on another device. The device record is a per-account flag (iOS `UserDefaults`, Android `onboarding_v1` shared preferences). It lets an offline launch skip the flow. If the server still has no completion when the profile next loads, the client sends it again. An unreachable profile shows the tabs and asks again on a later launch.

Finish and Skip on the calendar step both complete onboarding. Skip on the name step moves to the calendar step. A killed app resumes at the name step with the saved name filled in.

## Name step

The field starts with the profile's name: the provider name `handle_new_user` copied at sign-up, or the Apple name iOS saves after the first Apple authorization. If that name arrives after the step appears, it fills the field unless the person has typed. Names are trimmed and limited to 40 characters (`DisplayNameInput`). A blank name is stored as `NULL`, which every client already shows as "Anonymous".

Continue shows the name at once and saves it in the background, as does the completion. Each write is tried up to four times with exponential backoff and stops when the account changes.

## Calendar step

Both steps read and change the same state as the Calendar Integration settings, so the two screens stay in sync.

- **Apple Calendar** (iOS only) asks for full calendar access only when Connect is tapped, then turns on the same per-account preference as the Settings toggle. When the device denies or restricts access, the row offers Open Settings, and it rereads access when the app becomes active.
- **Google Calendar** starts the existing read-only free/busy OAuth flow. Closing the Google sheet now leaves the calendar unconnected without an error, in Settings too. Other failures show "Couldn't connect. Try again."

Android omits the Apple Calendar row; the device calendar stays in Settings there. Android's Google connect opens the browser and confirms the connection when the app resumes, as Settings does.

The iOS steps hide the navigation bar, which also turns off the system back swipe, so the calendar step goes back on a rightward swipe from the leading edge or VoiceOver's escape gesture. Android uses system back.

## Hosted rollout

Apply the migration before releasing either app. Against the old schema, `get_my_profile` has no `onboarding_completed_at`, so every existing account would see onboarding once on each device, and `complete_onboarding` wouldn't exist to record it. The migration adds a nullable column, rewrites every `profiles` row for the backfill, and briefly disables `update_profiles_updated_at` inside its transaction.

Accounts that signed up on the web after the migration see onboarding the first time they sign in to a native app, because the web has no onboarding.
