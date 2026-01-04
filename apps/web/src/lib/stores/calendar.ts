import { writable } from 'svelte/store'
import { supabase, type PollTimeOption } from '$lib/supabase'
import { session } from './auth'
import { browser } from '$app/environment'

// Calendar stores
export const calendarEnabled = writable(false)
export const calendarLoading = writable(false)
export const calendarConflicts = writable<Set<string>>(new Set())

/**
 * Initialize calendar state from user profile
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
    calendarEnabled.set(true)
  }
}

/**
 * Enable calendar integration by calling the store-calendar-token Edge Function
 * This extracts the OAuth refresh token from auth.identities and stores it
 */
export async function enableCalendarIntegration(): Promise<boolean> {
  calendarLoading.set(true)

  try {
    // Get current session
    const { data: { session: currentSession } } = await supabase.auth.getSession()
    if (!currentSession) {
      throw new Error('Not authenticated')
    }

    // Call Edge Function to store calendar token
    const { data, error } = await supabase.functions.invoke('store-calendar-token', {
      headers: {
        Authorization: `Bearer ${currentSession.session?.access_token}`
      }
    })

    if (error) {
      // Check if error is because user hasn't granted calendar scope
      if (error.message?.includes('No calendar refresh token found')) {
        // Need to re-authenticate with calendar scope
        throw new Error('Please sign out and sign in again to grant calendar access')
      }
      throw error
    }

    // If successful, update local state
    calendarEnabled.set(true)
    return true
  } catch (err) {
    console.error('Failed to enable calendar integration:', err)
    calendarEnabled.set(false)
    throw err
  } finally {
    calendarLoading.set(false)
  }
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
 * Calls the check-calendar-conflicts Edge Function
 */
export async function checkCalendarConflicts(timeOptions: PollTimeOption[]) {
  if (!timeOptions.length) {
    calendarConflicts.set(new Set())
    return
  }

  calendarLoading.set(true)

  try {
    const { data: { session: currentSession } } = await supabase.auth.getSession()
    if (!currentSession) {
      throw new Error('Not authenticated')
    }

    // Format time options for the Edge Function
    const formattedOptions = timeOptions.map(opt => ({
      id: opt.id,
      start_time: opt.start_time,
      end_time: opt.end_time
    }))

    // Call Edge Function to check conflicts
    const { data, error } = await supabase.functions.invoke('check-calendar-conflicts', {
      body: { timeOptions: formattedOptions },
      headers: {
        Authorization: `Bearer ${currentSession.session?.access_token}`
      }
    })

    if (error) {
      console.error('Failed to check calendar conflicts:', error)
      // Fail silently - don't block user
      calendarConflicts.set(new Set())
      return
    }

    // Update conflicts store with returned IDs
    const conflictIds = data?.conflictingIds || []
    calendarConflicts.set(new Set(conflictIds))
  } catch (err) {
    console.error('Error during calendar conflict check:', err)
    // Fail silently - don't block user
    calendarConflicts.set(new Set())
  } finally {
    calendarLoading.set(false)
  }
}
