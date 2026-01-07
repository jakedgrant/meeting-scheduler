# Calendar Integration Implementation Plan

**Branch:** `feature/calendar-integration`
**Date:** January 4, 2026
**Status:** In Progress

## Overview

Add Google Calendar (web) and Apple Calendar (mobile iOS) integration to automatically mark poll time options as "unavailable" when calendar conflicts exist. Read-only access with user-controlled opt-in via settings toggle.

### Key Requirements
- **Web:** Google Calendar API with OAuth, read-only scope
- **Mobile:** EventKit (iOS native), local calendar access
- **Auto-mark:** Automatic - mark unavailable on conflict, user can override
- **Control:** Optional via settings toggle

---

## Implementation Phases

### Phase 1: Database ✅
- [x] Create migration `00008_add_calendar_integration.sql`
  - Add `calendar_integration_enabled` BOOLEAN
  - Add `google_calendar_refresh_token` TEXT
  - Add `google_calendar_token_expires_at` TIMESTAMPTZ
  - Create index on token expiry

### Phase 2: Backend Edge Functions ✅
- [x] Create `store-calendar-token` function
  - Extracts OAuth refresh token from `auth.identities`
  - Stores encrypted token in profiles table
  - Sets calendar_integration_enabled = true

- [x] Create `check-calendar-conflicts` function
  - Accepts array of time options
  - Calls Google Calendar API for single date range (batched)
  - Returns list of conflicting option IDs
  - Handles token refresh with expiry checking
  - Fails gracefully on network/permission errors

### Phase 3: Mobile Implementation (iOS)
- [ ] Create `CalendarService.swift`
  - Observable pattern with EventKit
  - Request calendar permission flow
  - Batch query for all time options
  - Filter all-day and declined events
  - Sync preference to Supabase + UserDefaults

- [ ] Update `Info.plist`
  - Add NSCalendarsUsageDescription

- [ ] Update `SettingsView.swift`
  - Add calendar integration toggle
  - Show connected status

- [ ] Update `PollDetailView.swift`
  - Check conflicts when loading poll
  - Auto-mark unavailable for conflicts
  - Display conflict indicator badge
  - Allow user override

### Phase 4: Web Implementation
- [ ] Create `calendar.ts` Svelte store
  - `calendarEnabled`, `calendarLoading`, `calendarConflicts` stores
  - `enableCalendarIntegration()` - calls Edge Function
  - `disableCalendarIntegration()` - clears tokens
  - `checkCalendarConflicts()` - checks for conflicts

- [ ] Update `auth.ts`
  - Add calendar.readonly scope to Google OAuth
  - Add access_type: offline and prompt: consent

- [ ] Update `settings/+page.svelte`
  - Add calendar integration toggle
  - Show connected status

- [ ] Update `polls/[id]/+page.svelte`
  - Check conflicts on poll load
  - Auto-mark unavailable (if no existing response)
  - Display conflict indicator badge

### Phase 5: Testing & QA
- [ ] Manual testing on mobile
  - Permission grant flow
  - Permission denial flow
  - Auto-marking behavior
  - User override behavior
  - Settings toggle persistence

- [ ] Manual testing on web
  - OAuth flow with calendar scope
  - Token storage/retrieval
  - Conflict detection
  - Auto-marking behavior
  - Setting persistence

- [ ] Edge case testing
  - Token expiration
  - Permission revoked mid-session
  - Network failures
  - All-day events (should be ignored)
  - Declined events (should be ignored)
  - User sign out (tokens cleared)

---

## Critical Files

### Database
- `supabase/migrations/00008_add_calendar_integration.sql` ✅

### Backend
- `supabase/functions/store-calendar-token/index.ts` ✅
- `supabase/functions/check-calendar-conflicts/index.ts` ✅

### Mobile
- `apps/mobile/Sources/Shared/Services/CalendarService.swift` (TODO)
- `apps/mobile/MeetingScheduler/MeetingScheduler/Info.plist` (TODO)
- `apps/mobile/Sources/MeetingSchedulerApp/Views/SettingsView.swift` (TODO)
- `apps/mobile/Sources/MeetingSchedulerApp/Views/PollDetailView.swift` (TODO)

### Web
- `apps/web/src/lib/stores/calendar.ts` (TODO)
- `apps/web/src/lib/stores/auth.ts` (TODO)
- `apps/web/src/routes/settings/+page.svelte` (TODO)
- `apps/web/src/routes/polls/[id]/+page.svelte` (TODO)

---

## Key Architectural Decisions

### Batched Queries
- Web: Single Google Calendar API call for entire date range (all time options)
- Mobile: Single EventKit predicate query for date range
- **Benefit:** Prevents N+1 query problem, improves performance

### Privacy-First Approach
- No event data cached in database
- Only conflict detection (binary check)
- No event titles, descriptions, or attendees stored
- All queries are on-demand

### Error Handling
- Network failures fail gracefully (assume no conflicts)
- Permission denial auto-disables feature
- Token expiration auto-refreshes
- Re-authentication required for new OAuth scopes (web)

### User Control
- Optional feature via settings toggle
- Users can enable/disable at any time
- Users can manually override auto-marked availability
- Tokens immediately deleted when feature disabled

---

## Privacy & Security

### What We Store
- OAuth refresh tokens (encrypted by Supabase)
- User preference boolean
- Token expiry timestamp

### What We Don't Store
- Calendar event titles, descriptions, attendees
- Event locations or notes
- Any calendar event data

### Permissions
- Web: `calendar.readonly` scope only
- Mobile: System calendar read-only access (EventKit)
- No write/modify capabilities

---

## Performance Metrics

### Google Calendar API
- Quota: 1,000,000 requests/day (free tier)
- Per-user: ~100 requests/minute
- Our usage: ~1 request per poll view (batched)
- Expected: Well within limits

### Mobile EventKit
- Single local query for date range
- No network overhead
- Filters applied in-memory

---

## Out of Scope (V1)

**Not included:**
- Write/create calendar events
- Display event titles/details
- Multiple calendar selection
- Microsoft Outlook/Exchange
- CalDAV for Apple Calendar on web

**Potential V2 features:**
- Event creation after poll closes
- Calendar picker
- Conflict detail tooltips
- Microsoft 365 integration

---

## Testing Checklist

### Mobile
- [ ] Enable calendar integration → permission dialog shown
- [ ] Grant permission → toggle enabled, saved to UserDefaults + Supabase
- [ ] Deny permission → toggle reverts to off
- [ ] View poll with no conflicts → no auto-marking
- [ ] View poll with conflicts → auto-mark as unavailable
- [ ] Manually override auto-marked → respected
- [ ] Disable integration → conflicts cleared, tokens deleted
- [ ] Revoke permission in OS settings → feature auto-disables

### Web
- [ ] Click enable calendar → sign out/sign in prompt if not authorized
- [ ] Sign in with calendar scope → toggle enabled
- [ ] View poll with no conflicts → no auto-marking
- [ ] View poll with conflicts → auto-mark as unavailable
- [ ] Manually override auto-marked → respected
- [ ] Disable integration → conflicts cleared, tokens cleared
- [ ] Sign out → verify tokens deleted

### Error Cases
- [ ] Network failure during conflict check → graceful degradation
- [ ] Token expired → auto-refresh works
- [ ] Google Calendar API rate limit → handled gracefully
- [ ] Permission error → feature auto-disables

---

## Deployment Checklist

- [ ] All migration files created
- [ ] All Edge Functions deployed
- [ ] Mobile: CalendarService created
- [ ] Mobile: UI updated
- [ ] Web: Calendar store created
- [ ] Web: UI updated
- [ ] Full test suite passes
- [ ] Manual testing complete
- [ ] Code review approved
- [ ] Git commit created
- [ ] Branch pushed to remote
- [ ] Pull request created

---

## Notes

### Google OAuth Scopes
New Google sign-in users will automatically get calendar scope if requested at OAuth time. Existing users will need to:
1. Sign out
2. Sign in again
3. Grant calendar access when prompted
4. Enable calendar integration in settings

### iOS Permission Handling
iOS 17+ changed permission model to `fullAccess` vs older `authorized`. CalendarService handles both cases.

### Token Storage
Google refresh tokens are long-lived (until revoked). Access tokens expire in ~1 hour and are auto-refreshed by Edge Function.

---

## References

- [Google Calendar API Documentation](https://developers.google.com/calendar/api/guides/overview)
- [EventKit Framework Documentation](https://developer.apple.com/documentation/eventkit)
- [Supabase Edge Functions](https://supabase.com/docs/guides/functions)
