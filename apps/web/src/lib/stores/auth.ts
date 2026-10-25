import { writable, derived, get } from 'svelte/store'
import type { User, Session } from '@supabase/supabase-js'
import { supabase, ownedAuth, type Profile } from '$lib/supabase'
import { initRevenueCat, setRevenueCatIdentity } from '$lib/revenuecat'
import { browser } from '$app/environment'
import { captureSession, transitionSession } from '$lib/session-scope'
import { sessionOwner } from '$lib/owned-auth'
import { createSessionExpiry } from '$lib/session-expiry'

// Core auth stores
export const user = writable<User | null>(null)
export const session = writable<Session | null>(null)
export const profile = writable<Profile | null>(null)
export const authLoading = writable(browser)
export const authCallbackError = writable<string | null>(null)
const signedOutOwners = new Set<string>()
let callbackPending = false

// Derived store for authentication status
export const isAuthenticated = derived(user, ($user) => $user !== null)

const expiry = createSessionExpiry()
let owners = 0
let stopObserver: (() => void) | undefined
let lifetime = 0
let authRevision = 0
let profileRevision = 0
let deferred: ReturnType<typeof setTimeout> | undefined
let validation: ReturnType<typeof setTimeout> | undefined
let profileRequest: AbortController | undefined
let needsProfile = false

function deferDependentWork(load = false) {
  needsProfile ||= load
  if (deferred) clearTimeout(deferred)
  const scope = captureSession()
  const mounted = lifetime
  deferred = setTimeout(() => {
    deferred = undefined
    if (!owners || mounted !== lifetime || !scope.isCurrent()) return
    // These calls may acquire the Supabase auth lock. Never start them in the
    // synchronous onAuthStateChange callback, including INITIAL_SESSION.
    if (scope.accountId && needsProfile) void loadProfile(scope.accountId)
    needsProfile = false
    void initRevenueCat().catch(() => { /* Billing exposes its own unavailable state. */ })
  }, 0)
}

function acceptSession(next: Session | null, event = 'RESTORED') {
  if (next && (expiry.isExpired(next.expires_at) || signedOutOwners.has(sessionOwner(next)!))) next = null
  const previousSession = get(session)
  const previous = get(user)?.id ?? null
  const account = next?.user.id ?? null
  const renewed = !!previousSession && !!next && sessionOwner(previousSession) !== sessionOwner(next)
  const boundary = previous !== account || renewed
  if (boundary) {
    needsProfile = false
    profileRevision++
    profileRequest?.abort()
    profile.set(null)
  }
  transitionSession(account, renewed)
  setRevenueCatIdentity(account)
  session.set(next)
  user.set(next?.user ?? null)
  authLoading.set(callbackPending)
  expiry.watch(next?.expires_at, () => {
    authRevision++
    acceptSession(null, 'EXPIRED')
  })
  deferDependentWork(boundary || event === 'USER_UPDATED' || event === 'RESTORED')
}

function observeSession(event: string, hinted: Session | null, mounted: number) {
  const revision = ++authRevision
  const current = get(user)?.id ?? null
  const boundary = current !== (hinted?.user.id ?? null)
  if (validation) clearTimeout(validation)
  // Every event is a hint: even a same-account broadcast can carry an obsolete
  // token, expiry or user object. Keep visible state for ordinary refresh while
  // verifying current SDK storage after the auth lock is released.
  if (boundary) {
    if (deferred) clearTimeout(deferred)
    deferred = undefined
    needsProfile = false
    profileRevision++
    profileRequest?.abort()
    expiry.dispose()
    transitionSession(null)
    setRevenueCatIdentity(null)
    session.set(null)
    user.set(null)
    profile.set(null)
    authLoading.set(true)
  }
  validation = setTimeout(() => {
    validation = undefined
    void supabase.auth.getSession().then(({ data, error }) => {
      if (!owners || mounted !== lifetime || revision !== authRevision) return
      const verified = error ? null : data.session
      // Supabase's internal listener also consumes broadcast hints. Reconcile
      // Realtime's credential to verified storage before new channels are made.
      const visible = verified && !signedOutOwners.has(sessionOwner(verified)!) ? verified : null
      void ownedAuth.syncRealtime(visible).catch(() => {})
      acceptSession(visible, event)
    }).catch(() => {
      if (owners && mounted === lifetime && revision === authRevision) acceptSession(null, event)
    })
  }, 0)
}

/** Synchronous ownership lets unmount dispose even while restoration is pending. */
export function initAuth() {
  if (!browser) return () => {}
  owners++
  if (owners === 1) {
    const mounted = ++lifetime
    authLoading.set(true)
    const revision = authRevision
    const { data: { subscription } } = supabase.auth.onAuthStateChange((event, next) => {
      if (mounted !== lifetime || !owners) return
      observeSession(event, next, mounted)
    })
    const stopStorage = ownedAuth.subscribe((hint, external) => {
      // Our queued cleanup/publication is only a request to re-read current
      // SDK storage. Its old snapshot cannot synchronously clear newer UI.
      if (mounted === lifetime && owners) observeSession('STORAGE_CHANGED', external ? hint : get(session), mounted)
    })
    stopObserver = () => { subscription.unsubscribe(); stopStorage() }
    const callbackURL = typeof window !== 'undefined' && window.location.pathname === '/auth/callback'
      ? new URL(window.location.href) : null
    callbackPending = !!callbackURL
    authCallbackError.set(null)
    const restoration = async () => {
      if (callbackURL) {
        try { await ownedAuth.complete(callbackURL, () => mounted === lifetime && owners > 0) }
        catch (error) { if (mounted === lifetime && owners) authCallbackError.set(error instanceof Error ? error.message : 'Sign-in could not be verified') }
        if (mounted !== lifetime || !owners) return
        callbackPending = false
        observeSession('CALLBACK_FINISHED', null, mounted)
        return
      }
      try {
        const { data, error } = await supabase.auth.getSession()
        if (mounted === lifetime && owners && authRevision === revision) acceptSession(error ? null : data.session)
      } catch {
        if (mounted === lifetime && owners && authRevision === revision) acceptSession(null)
      }
    }
    void restoration()
  }
  let disposed = false
  return () => {
    if (disposed) return
    disposed = true
    if (--owners) return
    lifetime++
    callbackPending = false
    stopObserver?.()
    stopObserver = undefined
    if (deferred) clearTimeout(deferred)
    if (validation) clearTimeout(validation)
    validation = undefined
    deferred = undefined
    profileRevision++
    profileRequest?.abort()
    expiry.dispose()
    transitionSession(null)
    setRevenueCatIdentity(null)
    session.set(null)
    user.set(null)
    profile.set(null)
    authLoading.set(false)
    // Provider cleanup is ordered behind any in-flight provider operation.
    void initRevenueCat().catch(() => {})
  }
}

async function loadProfile(userId: string) {
  const scope = captureSession()
  const revision = ++profileRevision
  profileRequest?.abort()
  const controller = new AbortController()
  profileRequest = controller
  try {
    const { data, error } = await supabase.from('profiles').select('*').eq('id', userId)
      .abortSignal(controller.signal).single()
    if (!scope.isCurrent() || revision !== profileRevision || !owners) return
    if (error) return
    profile.set(data as Profile)
  } catch { /* Keep a same-account profile during a transient refresh failure. */ }
}

// Auth actions
export async function signInWithGoogle() { return signInWithProvider('google') }
export async function signInWithApple() { return signInWithProvider('apple') }
async function signInWithProvider(provider: 'google' | 'apple') {
  const scope = captureSession()
  const url = await ownedAuth.start({ provider }, get(session), window.location.origin)
  if (scope.isCurrent() && url) window.location.assign(url)
}
export async function signInWithMagicLink(email: string) {
  await ownedAuth.start({ email }, get(session), window.location.origin)
}

export async function signOut() {
  const original = get(session)
  if (!original) return false
  signedOutOwners.add(sessionOwner(original)!)
  authRevision++
  if (validation) clearTimeout(validation)
  validation = undefined
  // Visible state and command ownership end before SDK initialization, a
  // queued credential installation or remote revocation can delay cleanup.
  acceptSession(null, 'EXPLICIT_SIGN_OUT')
  const endedScope = captureSession()
  void ownedAuth.syncRealtime(null).catch(() => {})
  const { local, remote } = ownedAuth.signOut(original)
  void remote.catch(() => {})
  try {
    await local
    await remote
  } catch (error) {
    if (!endedScope.isCurrent() || get(user)) return false
    throw error
  }
  return endedScope.isCurrent() && get(user) === null
}

export async function updateProfile(updates: Partial<Profile>) {
  const currentUser = get(user)
  const scope = captureSession()
  const revision = ++profileRevision
  profileRequest?.abort()

  if (!currentUser) throw new Error('Not authenticated')

  const { data, error } = await supabase
    .from('profiles')
    .update(updates)
    .abortSignal(scope.signal)
    .eq('id', currentUser.id)
    .select()
    .single()

  if (!scope.isCurrent() || revision !== profileRevision) throw new Error('Session changed')
  if (error) throw error
  profile.set(data as Profile)
}
