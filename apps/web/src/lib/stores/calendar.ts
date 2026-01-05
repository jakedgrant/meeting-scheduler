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
 * Calls Edge Function with Supabase authentication
 * Edge Function handles Google Calendar API calls server-side (secure)
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

    console.log('Calling check-calendar-conflicts Edge Function')

    // Call Edge Function - Supabase automatically includes the session token
    const { data, error } = await supabase.functions.invoke('check-calendar-conflicts', {
      body: {
        timeOptions: timeOptions.map(opt => ({
          id: opt.id,
          start_time: opt.start_time,
          end_time: opt.end_time
        }))
      }
    })

    if (error) {
      console.error('Edge Function error:', error)
      calendarConflicts.set(new Set())
      return
    }

    if (!data || !Array.isArray(data.conflictingIds)) {
      console.warn('Invalid response from Edge Function:', data)
      calendarConflicts.set(new Set())
      return
    }

    console.log('Conflicting time option IDs:', data.conflictingIds)
    calendarConflicts.set(new Set(data.conflictingIds))
  } catch (err) {
    console.error('Error during calendar conflict check:', err)
    // Fail silently - don't block user
    calendarConflicts.set(new Set())
  } finally {
    calendarLoading.set(false)
  }
}
