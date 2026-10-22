import { writable, derived, get } from 'svelte/store'
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
  const { data: { subscription } } = supabase.auth.onAuthStateChange((event, newSession) => {
    session.set(newSession)
    user.set(newSession?.user ?? null)

    if (event === 'SIGNED_IN' && newSession?.user) {
      const userId = newSession.user.id
      setTimeout(() => {
        if (get(user)?.id !== userId) return
        void loadProfile(userId)
        void initRevenueCat(userId)
      }, 0)
    }

    if (event === 'SIGNED_OUT') {
      profile.set(null)
      setTimeout(() => { if (!get(user)) void initRevenueCat() }, 0)
    }
  })
  return () => subscription.unsubscribe()
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

  if (get(user)?.id === userId) profile.set(data as Profile)
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
  const currentUser = get(user)

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
