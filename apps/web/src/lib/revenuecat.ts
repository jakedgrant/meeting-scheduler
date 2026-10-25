import { Purchases, type CustomerInfo, type Package } from '@revenuecat/purchases-js'
import { browser } from '$app/environment'

const revenueCatWebKey = import.meta.env.VITE_REVENUECAT_WEB_KEY

/** Serialize identity side effects and reads; an ignored old result cannot undo a new login. */
export function createRevenueCatIdentity(configure: (account: string) => Purchases) {
  let instance: Purchases | null = null
  let desired: string | null = null
  let revision = 0
  let tail: Promise<unknown> = Promise.resolve()
  const enqueue = <T>(operation: () => Promise<T>): Promise<T> => {
    const result = tail.then(operation)
    tail = result.catch(() => {})
    return result
  }
  async function reconcile() {
    while (true) {
      const started = revision
      const account = desired
      try {
        if (!account) {
          instance?.close()
          instance = null
        } else if (!instance) {
          instance = configure(account)
        } else if (instance.getAppUserId() !== account) {
          await instance.changeUser(account)
        }
      } catch (error) {
        if (started !== revision) continue
        // changeUser can fail after changing its local identity. Future calls
        // retry reconciliation; no stale instance is exposed in the meantime.
        instance?.close()
        instance = null
        throw error
      }
      if (started === revision) return instance
    }
  }
  return {
    setIdentity(account: string | null) {
      if (account !== desired) { desired = account; revision++ }
    },
    reconcile: () => enqueue(reconcile),
    current: () => desired && instance?.getAppUserId() === desired ? instance : null,
    run<T>(operation: (client: Purchases) => Promise<T>, empty: T): Promise<T> {
      const started = revision
      return enqueue(async () => {
        const client = await reconcile()
        if (!client || !desired || started !== revision) return empty
        const result = await operation(client)
        return started === revision ? result : empty
      })
    }
  }
}

const identity = createRevenueCatIdentity(account => Purchases.configure({ apiKey: revenueCatWebKey, appUserId: account }))
// This setter performs no SDK I/O and is safe in the synchronous auth callback.
export const setRevenueCatIdentity = identity.setIdentity
export async function initRevenueCat(): Promise<Purchases | null> {
  if (!browser || !revenueCatWebKey) return null
  return identity.reconcile()
}
export function getPurchases(): Purchases | null { return identity.current() }
export async function getCustomerInfo(): Promise<CustomerInfo | null> {
  if (!browser || !revenueCatWebKey) return null
  return identity.run(client => client.getCustomerInfo(), null)
}
export async function getOfferings(): Promise<Package[]> {
  if (!browser || !revenueCatWebKey) return []
  return identity.run(async client => (await client.getOfferings()).current?.availablePackages ?? [], [])
}
export async function purchasePackage(pkg: Package): Promise<CustomerInfo | null> {
  if (!browser || !revenueCatWebKey) return null
  return identity.run(async client => (await client.purchase({ rcPackage: pkg })).customerInfo, null)
}
export function hasEntitlement(customerInfo: CustomerInfo | null, entitlementId: string): boolean {
  return !!customerInfo && entitlementId in customerInfo.entitlements.active
}
export function hasProAccess(customerInfo: CustomerInfo | null): boolean {
  return hasEntitlement(customerInfo, 'pro_access') || hasEntitlement(customerInfo, 'team_access')
}
export function hasTeamAccess(customerInfo: CustomerInfo | null): boolean { return hasEntitlement(customerInfo, 'team_access') }
