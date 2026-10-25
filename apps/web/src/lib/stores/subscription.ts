import { writable, derived } from 'svelte/store'
import type { CustomerInfo, Package } from '@revenuecat/purchases-js'
import { supabase, type Subscription } from '$lib/supabase'
import {
  getCustomerInfo,
  getOfferings,
  purchasePackage,
  hasProAccess as checkProAccess,
  hasTeamAccess as checkTeamAccess
} from '$lib/revenuecat'
import { browser } from '$app/environment'
import { captureSession, sessionIdentity } from '$lib/session-scope'

// Subscription stores
export const subscription = writable<Subscription | null>(null)
export const customerInfo = writable<CustomerInfo | null>(null)
export const offerings = writable<Package[]>([])
export const subscriptionLoading = writable(false)

// Derived stores for entitlement checks
export const hasProAccess = derived(customerInfo, ($customerInfo) => checkProAccess($customerInfo))
export const hasTeamAccess = derived(customerInfo, ($customerInfo) => checkTeamAccess($customerInfo))
export const isPremium = derived(hasProAccess, ($hasProAccess) => $hasProAccess)

let request = 0
let offeringsRequest = 0
let reloadTimer: ReturnType<typeof setTimeout> | undefined
sessionIdentity.subscribe(() => {
  request++
  offeringsRequest++
  if (reloadTimer) clearTimeout(reloadTimer)
  reloadTimer = undefined
  subscription.set(null)
  customerInfo.set(null)
  offerings.set([])
  subscriptionLoading.set(false)
})

/** Mount owns the deferred listener; subscribing itself never acquires the auth lock. */
let subscriptionOwners = 0
let stopSubscription: (() => void) | undefined
export function watchSubscription() {
  if (!browser) return () => {}
  if (++subscriptionOwners === 1) {
    let timer: ReturnType<typeof setTimeout> | undefined
    const stop = sessionIdentity.subscribe(identity => {
      if (timer) clearTimeout(timer)
      if (identity.accountId) timer = setTimeout(() => { void loadSubscription() }, 0)
    })
    stopSubscription = () => {
      if (timer) clearTimeout(timer)
      if (reloadTimer) clearTimeout(reloadTimer)
      stop()
      request++
      offeringsRequest++
    }
  }
  let disposed = false
  return () => {
    if (disposed) return
    disposed = true
    if (--subscriptionOwners === 0) { stopSubscription?.(); stopSubscription = undefined }
  }
}

// Supabase remains the server of record. Provider state is only a purchase projection.
export async function loadSubscription() {
  if (!browser) return
  const scope = captureSession()
  const revision = ++request
  if (!scope.accountId) return
  const current = () => scope.isCurrent() && revision === request
  subscriptionLoading.set(true)
  try {
    const { data, error } = await supabase.from('subscriptions').select('*')
      .eq('user_id', scope.accountId).abortSignal(scope.signal).single()
    if (!current()) return
    subscription.set(error ? null : data as Subscription | null)
    try {
      const info = await getCustomerInfo()
      if (current()) customerInfo.set(info)
    } catch { if (current()) customerInfo.set(null) }
  } catch {
    if (current()) { subscription.set(null); customerInfo.set(null) }
  } finally {
    if (current()) subscriptionLoading.set(false)
  }
}

export async function loadOfferings() {
  if (!browser) return
  const scope = captureSession()
  const revision = ++offeringsRequest
  if (!scope.accountId) return
  try {
    const packages = await getOfferings()
    if (scope.isCurrent() && revision === offeringsRequest) offerings.set(packages)
  } catch {
    if (scope.isCurrent() && revision === offeringsRequest) offerings.set([])
  }
}

export async function purchase(pkg: Package): Promise<boolean> {
  const scope = captureSession()
  if (!scope.accountId) return false
  try {
    const info = await purchasePackage(pkg)
    if (!scope.isCurrent() || !info) return false
    customerInfo.set(info)
    if (reloadTimer) clearTimeout(reloadTimer)
    reloadTimer = setTimeout(() => {
      reloadTimer = undefined
      if (scope.isCurrent()) void loadSubscription()
    }, 2000)
    return true
  } catch (error) {
    if (!scope.isCurrent()) return false
    throw error
  }
}
