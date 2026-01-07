import { writable, derived } from 'svelte/store'
import type { User, Session } from '@supabase/supabase-js'
import { supabase, type Profile } from '$lib/supabase'
import { initRevenueCat } from '$lib/revenuecat'
import { browser } from '$app/environment'

// Core auth stores
export const user = writable<User | null>(null)
export const session = writable<Session | null>(null)
export const profile = writable<Profile | null>(null)
export const authLoading = writable(true)

// Derived store for authentication status
export const isAuthenticated = derived(user, ($user) => $user !== null)

// Initialize auth listener
export async function initAuth() {
  if (!browser) return

  // Get initial session
  const { data: { session: initialSession } } = await supabase.auth.getSession()

  if (initialSession) {
    session.set(initialSession)
    user.set(initialSession.user)
    await loadProfile(initialSession.user.id)
    await initRevenueCat(initialSession.user.id)
  }

  authLoading.set(false)

  // Listen for auth changes
  supabase.auth.onAuthStateChange(async (event, newSession) => {
    session.set(newSession)
    user.set(newSession?.user ?? null)

    if (event === 'SIGNED_IN' && newSession?.user) {
      await loadProfile(newSession.user.id)
      await initRevenueCat(newSession.user.id)
    }

    if (event === 'SIGNED_OUT') {
      profile.set(null)
      await initRevenueCat() // Reset to anonymous
    }
  })
}

async function loadProfile(userId: string) {
  const { data, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', userId)
    .single()

  if (error) {
    console.error('Failed to load profile:', error)
    return
  }

  profile.set(data as Profile)
}

// Auth actions
export async function signInWithGoogle() {
  const { error } = await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo: `${window.location.origin}/auth/callback`
    }
  })
  if (error) throw error
}

/**
 * Request calendar scope from Google
 * Called when user enables calendar integration
 * User will be prompted to re-authenticate and grant calendar access
 */
export async function requestCalendarScope() {
  console.log('requestCalendarScope - Starting OAuth flow with calendar scope')

  const { error } = await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo: `${window.location.origin}/auth/callback`,
      // Request calendar scope along with standard auth scopes
      scopes: 'openid email profile https://www.googleapis.com/auth/calendar.readonly',
      queryParams: {
        access_type: 'offline',
        prompt: 'consent',
        include_granted_scopes: 'true'
      }
    }
  })

  if (error) {
    console.error('OAuth error:', error)
    throw error
  }
}

export async function signInWithApple() {
  const { error } = await supabase.auth.signInWithOAuth({
    provider: 'apple',
    options: {
      redirectTo: `${window.location.origin}/auth/callback`
    }
  })
  if (error) throw error
}

export async function signInWithMagicLink(email: string) {
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: {
      emailRedirectTo: `${window.location.origin}/auth/callback`
    }
  })
  if (error) throw error
}

export async function signOut() {
  const { error } = await supabase.auth.signOut()
  if (error) throw error
}

export async function updateProfile(updates: Partial<Profile>) {
  const currentUser = await new Promise<User | null>(resolve => {
    const unsubscribe = user.subscribe(value => {
      resolve(value)
      unsubscribe()
    })
  })

  if (!currentUser) throw new Error('Not authenticated')

  const { data, error } = await supabase
    .from('profiles')
    .update(updates)
    .eq('id', currentUser.id)
    .select()
    .single()

  if (error) throw error
  profile.set(data as Profile)
}
