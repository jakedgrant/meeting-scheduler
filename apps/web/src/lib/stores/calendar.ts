import { writable } from 'svelte/store'
import { supabase, type PollTimeOption } from '$lib/supabase'
import { session, requestCalendarScope } from './auth'
import { browser } from '$app/environment'

// Calendar stores
export const calendarEnabled = writable(false)
export const calendarLoading = writable(false)
export const calendarConflicts = writable<Set<string>>(new Set())

/**
 * Initialize calendar state from user profile
 * Token persistence happens in the auth callback
 */
export async function initCalendar() {
  if (!browser) return

  // Get current session to load profile
  const { data: { session: currentSession } } = await supabase.auth.getSession()
  if (!currentSession?.user) return

  const { data: profile, error } = await supabase
    .from('profiles')
    .select('calendar_integration_enabled')
    .eq('id', currentSession.user.id)
    .single()

  if (error) {
    console.error('Failed to load calendar preference:', error)
    return
  }

  if (profile?.calendar_integration_enabled) {
    console.log('Calendar integration is enabled')
    calendarEnabled.set(true)
  }
}

/**
 * Check if calendar token is already persisted
 * Returns true if token exists in database
 */
async function hasPersistedToken(): Promise<boolean> {
  try {
    const { data: { session: currentSession } } = await supabase.auth.getSession()

    if (!currentSession?.user) {
      return false
    }

    const { data: profile, error } = await supabase
      .from('profiles')
      .select('google_calendar_refresh_token')
      .eq('id', currentSession.user.id)
      .single()

    if (error || !profile) {
      return false
    }

    return !!profile.google_calendar_refresh_token
  } catch (err) {
    console.error('Error checking for persisted token:', err)
    return false
  }
}

/**
 * Enable calendar integration
 * If user hasn't granted calendar scope yet, prompts them to re-authenticate
 * Tokens are persisted in the auth callback after OAuth redirect
 */
export async function enableCalendarIntegration(): Promise<boolean> {
  calendarLoading.set(true)

  try {
    // Check if token is already persisted
    const tokenExists = await hasPersistedToken()

    if (tokenExists) {
      // Already enabled
      console.log('Calendar token already persisted, enabling integration')
      calendarEnabled.set(true)
      return true
    }

    // Token not available, need to request calendar scope
    console.log('No calendar token found, redirecting to Google OAuth...')
    await requestCalendarScope()
    // Note: requestCalendarScope redirects, code below won't execute normally
    throw new Error('Redirecting to grant calendar scope')
  } catch (err) {
    console.error('Failed to enable calendar integration:', err)
    calendarEnabled.set(false)
    throw err
  } finally {
    calendarLoading.set(false)
  }
}

/**
 * Watch session changes to load calendar state after OAuth redirect
 * The actual token persistence happens in the auth callback
 */
export function watchCalendarToken() {
  if (!browser) return

  const unsubscribe = session.subscribe(async (currentSession) => {
    if (!currentSession?.user) {
      console.debug('No session user in watchCalendarToken')
      return
    }

    // Check if calendar integration was just enabled via OAuth callback
    try {
      const { data: profile, error } = await supabase
        .from('profiles')
        .select('calendar_integration_enabled')
        .eq('id', currentSession.user.id)
        .single()

      if (error) {
        console.error('Error fetching profile:', error)
        return
      }

      console.debug('watchCalendarToken - Profile calendar_integration_enabled:', profile?.calendar_integration_enabled)

      // Update local state if token was persisted
      if (profile?.calendar_integration_enabled) {
        console.log('Calendar integration detected as enabled')
        calendarEnabled.set(true)
      }
    } catch (err) {
      console.error('Error in watchCalendarToken:', err)
    }
  })

  // Return unsubscribe function for cleanup if needed
  return unsubscribe
}

/**
 * Disable calendar integration and clear tokens
 */
export async function disableCalendarIntegration() {
  calendarLoading.set(true)

  try {
    const { data: { session: currentSession } } = await supabase.auth.getSession()
    if (!currentSession?.user) {
      throw new Error('Not authenticated')
    }

    // Clear tokens from database
    const { error } = await supabase
      .from('profiles')
      .update({
        calendar_integration_enabled: false,
        google_calendar_refresh_token: null,
        google_calendar_token_expires_at: null
      })
      .eq('id', currentSession.user.id)

    if (error) throw error

    calendarEnabled.set(false)
    calendarConflicts.set(new Set())
  } catch (err) {
    console.error('Failed to disable calendar integration:', err)
    throw err
  } finally {
    calendarLoading.set(false)
  }
}

/**
 * Check for calendar conflicts with time options
 * Calls Google Calendar API directly from the browser using stored access token
 */
export async function checkCalendarConflicts(timeOptions: PollTimeOption[]) {
  if (!timeOptions.length) {
    calendarConflicts.set(new Set())
    return
  }

  calendarLoading.set(true)

  try {
    const { data: { session: currentSession } } = await supabase.auth.getSession()
    if (!currentSession?.user) {
      console.warn('No authenticated user for calendar conflict check')
      calendarConflicts.set(new Set())
      return
    }

    // Get the stored access token from profile
    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .select('google_calendar_access_token, google_calendar_token_expires_at')
      .eq('id', currentSession.user.id)
      .single()

    if (profileError || !profile?.google_calendar_access_token) {
      console.warn('No Google Calendar access token found')
      calendarConflicts.set(new Set())
      return
    }

    // Check if token is expired
    const expiresAt = new Date(profile.google_calendar_token_expires_at)
    if (expiresAt < new Date()) {
      console.warn('Google Calendar access token expired')
      calendarConflicts.set(new Set())
      return
    }

    console.log('Checking calendar conflicts for', timeOptions.length, 'time options')

    // Find the time range to query (min start to max end)
    const startTimes = timeOptions.map(opt => new Date(opt.start_time).getTime())
    const endTimes = timeOptions.map(opt => new Date(opt.end_time).getTime())
    const minTime = new Date(Math.min(...startTimes))
    const maxTime = new Date(Math.max(...endTimes))

    // Call Google Calendar API directly
    const params = new URLSearchParams({
      timeMin: minTime.toISOString(),
      timeMax: maxTime.toISOString(),
      singleEvents: 'true',
      maxResults: '100'
    })

    const response = await fetch(
      `https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`,
      {
        headers: {
          'Authorization': `Bearer ${profile.google_calendar_access_token}`
        }
      }
    )

    if (!response.ok) {
      console.error('Google Calendar API error:', response.status)
      calendarConflicts.set(new Set())
      return
    }

    const data = await response.json()
    const events = data.items || []
    console.log('Found', events.length, 'calendar events in time range')

    // Filter out events that don't count as busy
    const busyEvents = events.filter((event: any) => {
      if (event.status === 'cancelled') return false
      if (event.transparency === 'transparent') return false
      if (event.attendees?.some((att: any) => att.self && att.responseStatus === 'declined')) {
        return false
      }
      return true
    })

    console.log('Busy events:', busyEvents.length)

    // Check each time option for conflicts
    const conflictingIds: string[] = []

    for (const option of timeOptions) {
      const optionStart = new Date(option.start_time).getTime()
      const optionEnd = new Date(option.end_time).getTime()

      const hasConflict = busyEvents.some((event: any) => {
        const eventStart = new Date(event.start?.dateTime || event.start?.date).getTime()
        const eventEnd = new Date(event.end?.dateTime || event.end?.date).getTime()

        // Check for overlap
        return optionStart < eventEnd && optionEnd > eventStart
      })

      if (hasConflict) {
        conflictingIds.push(option.id)
      }
    }

    console.log('Conflicting time option IDs:', conflictingIds)
    calendarConflicts.set(new Set(conflictingIds))
  } catch (err) {
    console.error('Error during calendar conflict check:', err)
    // Fail silently - don't block user
    calendarConflicts.set(new Set())
  } finally {
    calendarLoading.set(false)
  }
}
