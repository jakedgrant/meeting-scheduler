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
import { user } from './auth'
import { browser } from '$app/environment'

// Subscription stores
export const subscription = writable<Subscription | null>(null)
export const customerInfo = writable<CustomerInfo | null>(null)
export const offerings = writable<Package[]>([])
export const subscriptionLoading = writable(false)

// Derived stores for entitlement checks
export const hasProAccess = derived(customerInfo, ($customerInfo) => checkProAccess($customerInfo))
export const hasTeamAccess = derived(customerInfo, ($customerInfo) => checkTeamAccess($customerInfo))
export const isPremium = derived(hasProAccess, ($hasProAccess) => $hasProAccess)

// Load subscription data from both Supabase (server of record) and RevenueCat (for purchases)
export async function loadSubscription() {
  if (!browser) return

  subscriptionLoading.set(true)

  try {
    // Get current user
    const currentUser = await new Promise<{ id: string } | null>(resolve => {
      const unsubscribe = user.subscribe(value => {
        resolve(value)
        unsubscribe()
      })
    })

    if (!currentUser) {
      subscription.set(null)
      customerInfo.set(null)
      return
    }

    // Load from Supabase (source of truth for subscription status)
    const { data: subData } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', currentUser.id)
      .single()

    subscription.set(subData as Subscription | null)

    // Also get RevenueCat customer info for purchase flows
    const info = await getCustomerInfo()
    customerInfo.set(info)

  } catch (err) {
    console.error('Failed to load subscription:', err)
  } finally {
    subscriptionLoading.set(false)
  }
}

// Load available packages for purchase
export async function loadOfferings() {
  if (!browser) return

  try {
    const packages = await getOfferings()
    offerings.set(packages)
  } catch (err) {
    console.error('Failed to load offerings:', err)
  }
}

// Purchase a subscription package
export async function purchase(pkg: Package): Promise<boolean> {
  try {
    const newCustomerInfo = await purchasePackage(pkg)
    if (newCustomerInfo) {
      customerInfo.set(newCustomerInfo)
      // Reload subscription from Supabase after webhook processes
      setTimeout(() => loadSubscription(), 2000)
      return true
    }
    return false
  } catch (err) {
    console.error('Purchase failed:', err)
    throw err
  }
}

// Check limits based on subscription
export function getMaxActivePolls(sub: Subscription | null): number {
  if (!sub?.is_active) return 1
  if (sub.entitlement === 'team_access') return Infinity
  if (sub.entitlement === 'pro_access') return Infinity
  return 1
}

export function getMaxParticipants(sub: Subscription | null): number {
  if (!sub?.is_active) return 10
  if (sub.entitlement === 'team_access') return 100
  if (sub.entitlement === 'pro_access') return 50
  return 10
}
