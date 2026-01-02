import { Purchases, type CustomerInfo, type Package } from '@revenuecat/purchases-js'
import { browser } from '$app/environment'

const revenueCatWebKey = import.meta.env.VITE_REVENUECAT_WEB_KEY

let purchasesInstance: Purchases | null = null

export async function initRevenueCat(userId?: string): Promise<Purchases | null> {
  if (!browser) return null
  if (!revenueCatWebKey) {
    console.warn('RevenueCat Web Key not configured')
    return null
  }

  try {
    if (userId) {
      purchasesInstance = Purchases.configure(revenueCatWebKey, userId)
    } else {
      purchasesInstance = Purchases.configure(revenueCatWebKey)
    }
    return purchasesInstance
  } catch (err) {
    console.error('Failed to initialize RevenueCat:', err)
    return null
  }
}

export function getPurchases(): Purchases | null {
  return purchasesInstance
}

export async function getCustomerInfo(): Promise<CustomerInfo | null> {
  if (!purchasesInstance) return null
  try {
    return await purchasesInstance.getCustomerInfo()
  } catch (err) {
    console.error('Failed to get customer info:', err)
    return null
  }
}

export async function getOfferings(): Promise<Package[]> {
  if (!purchasesInstance) return []
  try {
    const offerings = await purchasesInstance.getOfferings()
    const current = offerings.current
    if (!current) return []
    return current.availablePackages
  } catch (err) {
    console.error('Failed to get offerings:', err)
    return []
  }
}

export async function purchasePackage(pkg: Package): Promise<CustomerInfo | null> {
  if (!purchasesInstance) return null
  try {
    const { customerInfo } = await purchasesInstance.purchase({ rcPackage: pkg })
    return customerInfo
  } catch (err) {
    console.error('Purchase failed:', err)
    throw err
  }
}

export function hasEntitlement(customerInfo: CustomerInfo | null, entitlementId: string): boolean {
  if (!customerInfo) return false
  return entitlementId in customerInfo.entitlements.active
}

export function hasProAccess(customerInfo: CustomerInfo | null): boolean {
  return hasEntitlement(customerInfo, 'pro_access') || hasEntitlement(customerInfo, 'team_access')
}

export function hasTeamAccess(customerInfo: CustomerInfo | null): boolean {
  return hasEntitlement(customerInfo, 'team_access')
}
