// Where a visitor goes after sign-in and onboarding. The auth core loads this on every
// page, so it stays free of runtime imports.
import type { OnboardingStep } from './onboarding'

export const HOME = '/polls'

/**
 * Where to go after sign-in or onboarding. Only a same-origin path is accepted, never an
 * absolute or protocol-relative URL, and never a page that would loop back here.
 */
export function safeNext(value: string | null | undefined): string {
  if (!value || !value.startsWith('/') || value.startsWith('//') || value.includes('\\')) return HOME
  let url: URL
  try { url = new URL(value, 'https://meetful.invalid') } catch { return HOME }
  // Check what is returned, not just the input: dot segments can normalize to //host.
  if (url.origin !== 'https://meetful.invalid' || url.pathname.startsWith('//')) return HOME
  // The router matches the decoded path and ignores a trailing slash, so compare that form.
  let routed: string
  try { routed = decodeURI(url.pathname).replace(/\/+$/, '') } catch { return HOME }
  if (routed === '/welcome' || routed === '/auth' || routed.startsWith('/auth/')) return HOME
  return url.pathname + url.search + url.hash
}

/** The sign-in page, asked to return to this page afterwards. */
export function signInHref(current: URL): string {
  const next = safeNext(current.pathname + current.search)
  return next === HOME ? '/auth' : `/auth?${new URLSearchParams({ next })}`
}

export function welcomeHref(step: OnboardingStep, next: string): string {
  const query = new URLSearchParams({ step })
  if (next !== HOME) query.set('next', next)
  return `/welcome?${query}`
}
