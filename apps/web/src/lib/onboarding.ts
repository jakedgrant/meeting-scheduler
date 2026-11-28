// Pure rules for the /welcome flow. The page owns rendering and side effects.
import { CALENDAR_DECLINED_MESSAGE, parseCalendarResult, type CalendarResult } from './calendar-result'

export type OnboardingStep = 'name' | 'calendar'
export type CalendarState = 'not-connected' | 'connecting' | 'connected' | 'failed' | 'declined'

export const HOME = '/polls'
export const DISPLAY_NAME_MAX = 40
export const ANONYMOUS = 'Anonymous'
const NEXT_KEY = 'meetful:onboarding-next'

export const parseStep = (value: string | null): OnboardingStep => value === 'calendar' ? 'calendar' : 'name'

/**
 * Where to go after onboarding. Only a same-origin path is accepted, never an
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

export function welcomeHref(step: OnboardingStep, next: string): string {
  const query = new URLSearchParams({ step })
  if (next !== HOME) query.set('next', next)
  return `/welcome?${query}`
}

/** The name as it will be saved: trimmed, and null when blank so peers see "Anonymous". */
export function normalizeName(input: string): string | null {
  const trimmed = input.trim().slice(0, DISPLAY_NAME_MAX)
  return trimmed || null
}

// Graphemes, not UTF-16 units, so an emoji or accented initial stays whole.
const graphemes = new Intl.Segmenter()

export function previewOf(input: string): { name: string; initial: string | null } {
  const name = normalizeName(input)
  const first = name ? graphemes.segment(name)[Symbol.iterator]().next().value?.segment.toLocaleUpperCase() ?? null : null
  return { name: name ?? ANONYMOUS, initial: first }
}

/** Prefill from the profile, which the signup trigger seeds from the Google or Apple name. */
export function prefillName(profileName: string | null | undefined, metadata: Record<string, unknown> | undefined): string {
  const candidate = profileName ?? metadata?.full_name ?? metadata?.name
  return typeof candidate === 'string' ? candidate.trim().slice(0, DISPLAY_NAME_MAX) : ''
}

export function calendarState(input: {
  connected: boolean
  connecting: boolean
  result: CalendarResult | null
  startFailed: boolean
}): CalendarState {
  if (input.connected) return 'connected'
  if (input.connecting) return 'connecting'
  if (input.result === 'declined') return 'declined'
  if (input.result === 'failed' || input.startFailed) return 'failed'
  // A cancel on Google's screen is not an error.
  return 'not-connected'
}

export const CALENDAR_MESSAGES: Record<CalendarState, string> = {
  'not-connected': 'Google Calendar is not connected.',
  connecting: 'Connecting to Google Calendar…',
  connected: 'Google Calendar connected.',
  failed: "Couldn't connect. Try again.",
  declined: CALENDAR_DECLINED_MESSAGE
}

/** Runs an operation until it succeeds or the attempts run out, waiting between tries. */
export async function retry<T>(
  operation: () => Promise<T>,
  { delays = [1000, 3000], wait = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms)), shouldStop = () => false }:
    { delays?: number[]; wait?: (ms: number) => Promise<void>; shouldStop?: () => boolean } = {}
): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await operation()
    } catch (error) {
      if (attempt >= delays.length || shouldStop()) throw error
      await wait(delays[attempt])
      if (shouldStop()) throw error
    }
  }
}

/**
 * The consent round trip ends at a fixed /welcome?step=calendar, so the destination is kept
 * in this tab's session storage across that round trip.
 */
export function rememberNext(storage: Pick<Storage, 'setItem' | 'removeItem'> | undefined, next: string) {
  try {
    if (next === HOME) storage?.removeItem(NEXT_KEY)
    else storage?.setItem(NEXT_KEY, next)
  } catch { /* Storage can be unavailable; the flow then ends at home. */ }
}

export function recallNext(storage: Pick<Storage, 'getItem' | 'removeItem'> | undefined): string {
  try {
    const value = storage?.getItem(NEXT_KEY) ?? null
    storage?.removeItem(NEXT_KEY)
    return safeNext(value)
  } catch { return HOME }
}

type StoredProfile = { onboarding_completed_at: string | null; display_name: string | null; avatar_url: string | null }

export type WelcomeEntry =
  | { kind: 'leave'; to: string }
  | { kind: 'show'; next: string; result: CalendarResult | null; name: string; savedName: string | null; avatarUrl: string | null }

/**
 * Every web sign-in lands on /welcome, so this decides whether to show the flow
 * or send the account straight on. It fails open: a profile that can't be read
 * leaves for the app rather than holding someone in onboarding.
 */
export async function resolveWelcomeEntry(input: {
  url: URL
  storage: Pick<Storage, 'getItem' | 'removeItem'> | undefined
  loadProfile: () => Promise<StoredProfile>
  metadata: Record<string, unknown> | undefined
}): Promise<WelcomeEntry> {
  const result = parseCalendarResult(input.url.searchParams.get('calendar'))
  // Consent ends at a fixed URL, so after it the destination comes back from this tab's storage.
  const next = result ? recallNext(input.storage) : safeNext(input.url.searchParams.get('next'))
  let profile: StoredProfile
  try { profile = await input.loadProfile() } catch { return { kind: 'leave', to: next } }
  if (profile.onboarding_completed_at !== null) return { kind: 'leave', to: next }
  return {
    kind: 'show', next, result,
    name: prefillName(profile.display_name, input.metadata),
    savedName: profile.display_name,
    avatarUrl: profile.avatar_url
  }
}
