import { writable, get } from 'svelte/store'
import { supabase, type PollTimeOption } from '$lib/supabase'
import { session } from './auth'
import { browser } from '$app/environment'
import { captureSession, sessionIdentity } from '$lib/session-scope'

export const calendarEnabled = writable(false)
export const calendarLoading = writable(false)
export const calendarConflicts = writable<Set<string>>(new Set())
/** Options the last check could not cover; see docs/calendar-coverage.md (F16). */
export const calendarUnchecked = writable<Set<string>>(new Set())
/** What the last successful check read, for example "primary calendar". */
export const calendarCoverage = writable<string | null>(null)
export const calendarStatusError = writable<string | null>(null)
export const calendarAccountEmail = writable<string | null>(null)
export const calendarRequiresReconnect = writable(false)
export const calendarRevocationPending = writable(false)
let accountId: string | null = null
let generation = 0
let conflictRequest = 0
let conflictOptions = ''
let connectionMutation = false
let statusRequest = 0
const CHECK_FAILED = 'Google Calendar couldn\'t be checked. Options marked "Couldn\'t check" may still conflict.'

interface ConnectionStatus {
  connected: boolean
  accountEmail: string | null
  requiresReconnect: boolean
  revocationPending: boolean
}

function reset(account: string | null) {
  accountId = account
  generation++
  statusRequest++
  conflictRequest++
  conflictOptions = ''
  connectionMutation = false
  calendarEnabled.set(false)
  calendarLoading.set(false)
  clearConflictResults()
  calendarStatusError.set(null)
  calendarAccountEmail.set(null)
  calendarRequiresReconnect.set(false)
  calendarRevocationPending.set(false)
}

function clearConflictResults() {
  calendarConflicts.set(new Set())
  calendarUnchecked.set(new Set())
  calendarCoverage.set(null)
}

// State clears synchronously on every auth boundary, even with no mounted watcher.
sessionIdentity.subscribe(identity => reset(identity.accountId))

function applyStatus(data: ConnectionStatus) {
  if (typeof data?.connected !== 'boolean' || typeof data.requiresReconnect !== 'boolean' ||
      typeof data.revocationPending !== 'boolean' || !(data.accountEmail === null || typeof data.accountEmail === 'string')) {
    throw new Error('Calendar connection status could not be verified.')
  }
  calendarEnabled.set(data.connected)
  calendarAccountEmail.set(data.accountEmail)
  calendarRequiresReconnect.set(data.requiresReconnect)
  calendarRevocationPending.set(data.revocationPending)
}

async function connection<T>(body: Record<string, unknown>): Promise<T> {
  const scope = captureSession()
  const { data, error } = await supabase.functions.invoke<T>('calendar-connection', { body, signal: scope.signal })
  if (!scope.isCurrent()) throw new Error('Session changed')
  if (error || !data) throw new Error('Google Calendar could not be updated. Try again.')
  return data
}

export async function initCalendar() {
  if (!browser) return
  const userId = get(session)?.user.id ?? null
  if (accountId !== userId) reset(userId)
  if (!userId) return
  if (get(calendarLoading)) return
  const current = generation
  const request = ++statusRequest
  try {
    const data = await connection<ConnectionStatus>({ action: 'status' })
    if (generation === current && request === statusRequest) applyStatus(data)
  } catch {
    if (generation === current && request === statusRequest) calendarStatusError.set('Google Calendar connection could not be checked.')
  }
}

export async function enableCalendarIntegration(): Promise<boolean> {
  if (!get(session)?.user) throw new Error('Sign in before connecting a calendar.')
  if (accountId !== get(session)?.user.id) reset(get(session)?.user.id ?? null)
  const current = ++generation
  statusRequest++
  connectionMutation = true
  calendarLoading.set(true)
  calendarStatusError.set(null)
  try {
    const status = await connection<ConnectionStatus>({ action: 'status' })
    if (generation !== current) return false
    applyStatus(status)
    if (status.connected) return true
    const result = await connection<{ authorizationURL: string }>({ action: 'start', target: 'web', origin: window.location.origin })
    if (generation !== current) return false
    const url = new URL(result.authorizationURL)
    if (url.protocol !== 'https:' || url.hostname !== 'accounts.google.com' || url.pathname !== '/o/oauth2/v2/auth') {
      throw new Error('Calendar authorization could not be started.')
    }
    window.location.assign(url.toString())
    return true
  } finally {
    if (generation === current) { calendarLoading.set(false); connectionMutation = false }
  }
}

/** Schedule outside the synchronous auth callback; clear state on account changes. */
let calendarOwners = 0
let stopCalendar: (() => void) | undefined
export function watchCalendarConnection() {
  if (!browser) return () => {}
  if (++calendarOwners === 1) {
    let timer: ReturnType<typeof setTimeout> | undefined
    const unsubscribe = sessionIdentity.subscribe(identity => {
      if (timer) clearTimeout(timer)
      if (identity.accountId) timer = setTimeout(() => { void initCalendar() }, 0)
    })
    stopCalendar = () => { if (timer) clearTimeout(timer); unsubscribe(); reset(null) }
  }
  let disposed = false
  return () => {
    if (disposed) return
    disposed = true
    if (--calendarOwners === 0) { stopCalendar?.(); stopCalendar = undefined }
  }
}

export async function disableCalendarIntegration() {
  if (!get(session)?.user) return
  const current = ++generation
  statusRequest++
  connectionMutation = true
  conflictRequest++
  clearConflictResults()
  calendarLoading.set(true)
  calendarStatusError.set(null)
  try {
    const result = await connection<ConnectionStatus>({ action: 'disconnect' })
    if (generation !== current) return
    applyStatus(result)
    clearConflictResults()
  } finally {
    if (generation === current) { calendarLoading.set(false); connectionMutation = false }
  }
}

export async function checkCalendarConflicts(timeOptions: PollTimeOption[]) {
  if (!timeOptions.length) { conflictRequest++; conflictOptions = ''; clearConflictResults(); return }
  if (connectionMutation) return
  if (!get(session)?.user) return
  const current = generation
  const scope = captureSession()
  const request = ++conflictRequest
  const optionsKey = JSON.stringify(timeOptions.map(({ id, start_time, end_time }) =>
    ({ id, start_time, end_time })).sort((a, b) => a.id.localeCompare(b.id)))
  if (conflictOptions !== optionsKey) {
    conflictOptions = optionsKey
    clearConflictResults()
  }
  calendarLoading.set(true)
  calendarStatusError.set(null)
  try {
    const { data, error } = await supabase.functions.invoke('check-calendar-conflicts', { signal: scope.signal, body: {
      timeOptions: timeOptions.map(({ id, start_time, end_time }) => ({ id, start_time, end_time }))
    } })
    if (generation !== current || request !== conflictRequest) return
    // An unrecognized coverage cannot be labelled honestly, so it counts as unchecked.
    if (error || data?.success !== true || data.coverage !== 'primary' || !Array.isArray(data.conflictingIds) ||
        !data.conflictingIds.every((id: unknown) => typeof id === 'string')) {
      throw new Error('Calendar conflicts could not be checked.')
    }
    calendarConflicts.set(new Set(data.conflictingIds))
    calendarUnchecked.set(new Set())
    calendarCoverage.set('primary calendar')
  } catch {
    // Keep the last known busy options and mark every option unchecked instead of
    // reporting an empty, apparently successful check.
    if (generation === current && request === conflictRequest) {
      calendarUnchecked.set(new Set(timeOptions.map(option => option.id)))
      calendarCoverage.set(null)
      calendarStatusError.set(CHECK_FAILED)
    }
  } finally {
    if (generation === current && request === conflictRequest) calendarLoading.set(false)
  }
}
