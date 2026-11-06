import { writable, get } from 'svelte/store'
import type { FunctionArgs, FunctionName, FunctionReturns } from '$lib/database.types'
import { supabase, type Poll, type PollTimeOption, type PollParticipant, type AvailabilityResponse } from '$lib/supabase'
import { user } from './auth'
import { captureSession } from '$lib/session-scope'
import { startPollRefresh } from '$lib/poll-refresh'
import {
  GUEST_ACCESS_LOST_MESSAGE,
  browserStorage,
  clearGuestCapability,
  isGuestAccessDenied,
  isValidCapability,
  newGuestToken,
  readPendingGuestToken,
  savePendingGuestToken,
  clearPendingGuestToken,
  readGuestCapability,
  saveGuestCapability,
  type GuestCapability,
  type RpcError
} from '$lib/guest-capability'
import type { AvailabilitySave, AvailabilitySnapshot } from '$lib/availability-editor'
import type { CreationOperation, CreationResult } from '$lib/poll-creation'
import { IncompleteReadError, checkedPage, readAllPages, type Page } from '$lib/paged-read'
import {
  isAvailabilityResponse, isAvailabilitySnapshot, isCreationResult, isPollDetailAsGuest, isGuestJoinResult,
  isJoinResult, isPoll, isPollDetail, isSummaryRow, type PollDetail, type SummaryRow
} from '$lib/rpc-results'

// Poll stores
export const polls = writable<Poll[]>([])
export const createdPolls = writable<Poll[]>([])
export const joinedPolls = writable<Poll[]>([])

// Database-computed list fields, keyed by poll id (list_poll_summaries).
export type PollSummary = Omit<SummaryRow, 'poll' | 'role'>
export type PollListRole = SummaryRow['role']
export interface PollListSection { total: number; nextCursor: string | null; loadingMore: boolean }
const emptySection = (): PollListSection => ({ total: 0, nextCursor: null, loadingMore: false })
export const pollSummaries = writable<Record<string, PollSummary>>({})
export const pollListSections = writable<Record<PollListRole, PollListSection>>({ owner: emptySection(), member: emptySection() })
export const pollsLoadError = writable<string | null>(null)
export const POLL_LIST_PAGE_SIZE = 50
const RESPONSE_PAGE_SIZE = 1000
export const currentPoll = writable<Poll | null>(null)
export const currentPollTimeOptions = writable<PollTimeOption[]>([])
export const currentPollParticipants = writable<PollParticipant[]>([])
export const currentPollResponses = writable<AvailabilityResponse[]>([])
export const pollsLoading = writable(false)
// Signed-out participation in the current poll, verified by the server on each use.
export const currentGuest = writable<GuestCapability | null>(null)
// User-facing notice when a stored guest capability stops working.
export const guestNotice = writable<string | null>(null)

export const currentAvailability = writable<AvailabilitySnapshot | null>(null)
export const availabilityLoadError = writable<string | null>(null)
export const pollRefreshError = writable<string | null>(null)

const guestCapabilities = new Map<string, GuestCapability>()
const pendingGuestTokens = new Map<string, string>()
let pollUpdates: ReturnType<typeof startPollRefresh> | null = null
// A background read begun before a local mutation cannot publish over it.
let detailRevision = 0
let loadGeneration = 0
let requestedPollId: string | null = null
let identityGeneration = 0
let listGeneration = 0
// Full reloads and account changes only; a creation does not invalidate older pages.
let listReset = 0
let lastUserId: string | null = null
let detailOwner = 0
let listAbort = new AbortController()
let detailAbort = new AbortController()

// Invalidate in-flight reads and current detail at every account transition.
user.subscribe(value => {
  const userId = value?.id ?? null
  if (userId === lastUserId) return
  lastUserId = userId
  identityGeneration++
  listGeneration++
  listReset++
  listAbort.abort()
  listAbort = new AbortController()
  cleanupPollRealtime()
  resetPollList()
})

function resetPollList() {
  polls.set([])
  createdPolls.set([])
  joinedPolls.set([])
  pollSummaries.set({})
  pollListSections.set({ owner: emptySection(), member: emptySection() })
  pollsLoadError.set(null)
}

function capabilityForPoll(pollId: string) {
  const capability = guestCapabilities.get(pollId) ?? readGuestCapability(browserStorage(), pollId)
  if (capability) guestCapabilities.set(pollId, capability)
  return capability ?? null
}

function sessionRpc<Name extends FunctionName>(name: Name, args: FunctionArgs<Name>, signal = captureSession().signal) {
  return supabase.rpc(name, args).abortSignal(signal)
}

async function fetchSummaryPage(role: PollListRole, cursor: string | null, signal: AbortSignal) {
  const { data, error } = await sessionRpc('list_poll_summaries', {
    role_filter: role, page_size: POLL_LIST_PAGE_SIZE, page_cursor: cursor
  }, signal)
  if (error) throw error
  const page = checkedPage(data, isSummaryRow)
  if (page.items.some(item => item.role !== role)) throw new IncompleteReadError()
  return page
}

function summaryOf(item: SummaryRow): PollSummary {
  const { participant_count, time_option_count, earliest_start, latest_start } = item
  return { participant_count, time_option_count, earliest_start, latest_start }
}

function applySummaryPage(role: PollListRole, page: Page<SummaryRow>, append: boolean) {
  const target = role === 'owner' ? createdPolls : joinedPolls
  target.update(rows => {
    const incoming = page.items.map(item => item.poll)
    const base = append ? rows.filter(row => !incoming.some(poll => poll.id === row.id)) : []
    return [...base, ...incoming]
  })
  pollSummaries.update(map => ({
    ...map, ...Object.fromEntries(page.items.map(item => [item.poll.id, summaryOf(item)]))
  }))
  pollListSections.update(sections => ({
    ...sections,
    // Later pages omit the total; keep the first page's value.
    [role]: { total: page.total_count ?? sections[role].total, nextCursor: page.next_cursor, loadingMore: false }
  }))
  polls.set([...get(createdPolls), ...get(joinedPolls)])
}

// Load the first page of created and joined polls: two requests regardless of
// history size. Further pages load on demand through loadMorePolls.
export async function loadParticipatedPolls() {
  listReset++
  const generation = ++listGeneration
  listAbort.abort()
  listAbort = new AbortController()
  const currentUser = get(user)
  if (!currentUser) {
    resetPollList()
    return
  }

  pollsLoading.set(true)
  pollsLoadError.set(null)
  const identity = identityGeneration
  const signal = listAbort.signal

  try {
    const [owned, member] = await Promise.all([
      fetchSummaryPage('owner', null, signal), fetchSummaryPage('member', null, signal)
    ])
    if (identity !== identityGeneration || generation !== listGeneration) return
    pollSummaries.set({})
    applySummaryPage('owner', owned, false)
    applySummaryPage('member', member, false)
  } catch (err) {
    if (identity !== identityGeneration || generation !== listGeneration) return
    console.error('Failed to load polls')
    pollsLoadError.set('Could not load your polls. Please retry.')
  } finally {
    if (identity === identityGeneration && generation === listGeneration) pollsLoading.set(false)
  }
}

// Append the next page of one section. A full reload or account change drops it.
export async function loadMorePolls(role: PollListRole) {
  const section = get(pollListSections)[role]
  if (!section.nextCursor || section.loadingMore || !get(user)) return
  const generation = listReset
  const identity = identityGeneration
  pollListSections.update(sections => ({ ...sections, [role]: { ...sections[role], loadingMore: true } }))
  try {
    const page = await fetchSummaryPage(role, section.nextCursor, listAbort.signal)
    if (identity !== identityGeneration || generation !== listReset) return
    applySummaryPage(role, page, true)
  } catch {
    if (identity !== identityGeneration || generation !== listReset) return
    pollListSections.update(sections => ({ ...sections, [role]: { ...sections[role], loadingMore: false } }))
    pollsLoadError.set('Could not load more polls. Please retry.')
  }
}

// Legacy function for backward compatibility
export async function loadMyPolls() {
  return loadParticipatedPolls()
}

// Load a poll by share code. The lookup returns only the columns a joiner needs.
type PollByCode = FunctionReturns<'get_poll_by_code'>[number]
export async function loadPollByCode(code: string): Promise<PollByCode | null> {
  const identity = identityGeneration
  try {
    const { data, error } = await sessionRpc('get_poll_by_code', { code: code.toUpperCase() })

    if (identity !== identityGeneration) return null
    if (error) throw error
    if (!data || data.length === 0) return null

    return data[0]
  } catch (err) {
    console.error('Failed to load poll by code')
    return null
  }
}

function dropGuestCapability(pollId: string, expectedToken: string) {
  // A late denial must never revoke a capability acquired by a later join.
  const currentToken = guestCapabilities.get(pollId)?.token ?? pendingGuestTokens.get(pollId)
  if (currentToken !== expectedToken) return
  guestCapabilities.delete(pollId)
  pendingGuestTokens.delete(pollId)
  const storage = browserStorage()
  if (readGuestCapability(storage, pollId)?.token === expectedToken) clearGuestCapability(storage, pollId)
  if (readPendingGuestToken(storage, pollId) === expectedToken) clearPendingGuestToken(storage, pollId)
  if (requestedPollId === pollId) {
    currentGuest.set(null)
    guestNotice.set(GUEST_ACCESS_LOST_MESSAGE)
  }
}

// Signed-out guests cannot read participant rows; they read the same bounded
// detail and response pages through their capability. Returns false when the
// caller should use the normal path.
async function loadGuestPoll(pollId: string, guest: GuestCapability, generation: number, signal: AbortSignal): Promise<boolean> {
  let responses: AvailabilityResponse[]
  try {
    const detail = await readDetail(pollId, guest, signal)
    if (generation !== loadGeneration) return true
    currentGuest.set(guest)
    publishDetail(detail)
    responses = await readPollResponses(pollId, guest, signal)
  } catch (error) {
    if (generation !== loadGeneration) return true
    currentGuest.set(null)
    if (guestAccessLost(error)) {
      dropGuestCapability(pollId, guest.token)
      return false
    }
    throw error
  }
  if (generation !== loadGeneration) return true
  currentPollResponses.set(responses)
  await loadCurrentAvailability(pollId, guest.participantId, generation)
  if (generation !== loadGeneration) return true
  pollUpdates = startPollRefresh(() => refreshPoll(pollId, generation, guest))
  return true
}

// Load a single poll with all related data
export async function loadPoll(pollId: string) {
  stopPollUpdates()
  pollRefreshError.set(null)
  detailAbort.abort()
  detailAbort = new AbortController()
  const signal = AbortSignal.any([detailAbort.signal, captureSession().signal])
  pollsLoading.set(true)
  const generation = ++loadGeneration
  requestedPollId = pollId
  if (get(currentPoll)?.id !== pollId) {
    currentAvailability.set(null)
    currentPollResponses.set([])
    currentPollParticipants.set([])
  }
  availabilityLoadError.set(null)

  try {
    const guest = get(user) ? null : capabilityForPoll(pollId)
    currentGuest.set(null)
    if (guest && await loadGuestPoll(pollId, guest, generation, signal)) return

    // Poll, options and participants arrive together with their counts.
    const detail = await readDetail(pollId, null, signal)
    if (generation !== loadGeneration) return
    publishDetail(detail)

    // Responses can exceed one page; show them only once traversal is complete.
    const responses = await readPollResponses(pollId, null, signal)
    if (generation !== loadGeneration) return
    currentPollResponses.set(responses)

    const ownParticipant = detail.participants.find(participant => participant.user_id === get(user)?.id)
    if (ownParticipant) await loadCurrentAvailability(pollId, ownParticipant.id, generation)
    else currentAvailability.set(null)
    if (generation !== loadGeneration) return

    // Refetch only this authorized poll; unrelated database activity does no work.
    if (get(user)) pollUpdates = startPollRefresh(() => refreshPoll(pollId, generation))

  } catch (err) {
    if (generation !== loadGeneration) return
    console.error('Failed to load poll')
    currentPoll.set(null)
  } finally {
    if (generation === loadGeneration) pollsLoading.set(false)
  }
}

// Background reads publish only after every collection and the member snapshot
// are complete. The editor keeps dirty drafts at their original save version.
async function refreshPoll(pollId: string, generation: number, guest: GuestCapability | null = null) {
  const revision = detailRevision
  const isCurrent = () => generation === loadGeneration && revision === detailRevision
  const signal = AbortSignal.any([detailAbort.signal, captureSession().signal])
  // A dropped or replaced capability stops this schedule; a rejoin reloads.
  if (guest && capabilityForPoll(pollId)?.token !== guest.token) {
    stopPollUpdates()
    return
  }
  try {
    const detail = await readDetail(pollId, guest, signal)
    if (!isCurrent()) return
    const responses = await readPollResponses(pollId, guest, signal)
    if (!isCurrent()) return
    const participantId = guest?.participantId ?? detail.participants.find(row => row.user_id === get(user)?.id)?.id
    const snapshot = participantId ? await loadAvailability(pollId, participantId) : null
    if (!isCurrent()) return
    currentPoll.set(detail.poll)
    // Republishing identical options would repeat the page's calendar/provider check.
    if (JSON.stringify(get(currentPollTimeOptions)) !== JSON.stringify(detail.time_options)) {
      currentPollTimeOptions.set(detail.time_options)
    }
    currentPollParticipants.set(detail.participants)
    currentPollResponses.set(responses)
    currentAvailability.set(snapshot)
    availabilityLoadError.set(null)
    pollRefreshError.set(null)
  } catch (error) {
    if (!isCurrent()) return
    // Like a denied save, a lost capability keeps the poll and its join prompt.
    if (guest && guestAccessLost(error)) {
      stopPollUpdates()
      dropGuestCapability(pollId, guest.token)
      return
    }
    if ((error as { code?: string })?.code === '42501') {
      cleanupPollRealtime()
      return
    }
    pollRefreshError.set('Could not refresh this poll. Displayed results may be out of date. Retry before responding.')
  }
}

/** A guest capability that verifies but opens another poll. */
class ForeignGuestPollError extends Error {}

// A denied capability, or one for another poll, no longer opens this poll.
function guestAccessLost(error: unknown) {
  return error instanceof ForeignGuestPollError || isGuestAccessDenied(error as RpcError)
}

function guestArgs(guest: GuestCapability) {
  return { participant_uuid: guest.participantId, guest_token: guest.token }
}

// Members and guests read the same bounded contract; only authorization differs.
async function readDetail(pollId: string, guest: GuestCapability | null, signal: AbortSignal): Promise<PollDetail> {
  const { data, error } = guest
    ? await sessionRpc('get_poll_detail_as_guest', guestArgs(guest), signal)
    : await sessionRpc('get_poll_detail', { poll_uuid: pollId }, signal)
  if (error) throw error
  if (guest) {
    if (!isPollDetailAsGuest(data) || data.participant_id !== guest.participantId) throw new IncompleteReadError()
    if (data.poll.id !== pollId) throw new ForeignGuestPollError()
  }
  if (!isPollDetail(data) || data.poll.id !== pollId
      || data.time_options.length !== data.time_option_count
      || data.participants.length !== data.participant_count) {
    throw new IncompleteReadError()
  }
  return data
}

function publishDetail(detail: PollDetail) {
  currentPoll.set(detail.poll)
  currentPollTimeOptions.set(detail.time_options)
  currentPollParticipants.set(detail.participants)
}

function readPollResponses(pollId: string, guest: GuestCapability | null, signal: AbortSignal) {
  return readAllPages(async cursor => {
    const page = { page_size: RESPONSE_PAGE_SIZE, page_cursor: cursor }
    const { data, error } = guest
      ? await sessionRpc('list_poll_responses_as_guest', { ...guestArgs(guest), ...page }, signal)
      : await sessionRpc('list_poll_responses', { poll_uuid: pollId, ...page }, signal)
    if (error) throw error
    return checkedPage(data, isAvailabilityResponse)
  }, response => `${response.participant_id}:${response.time_option_id}`)
}

// The server validates and commits options, quota and any pass in one transaction.
export async function createPoll(operation: CreationOperation): Promise<CreationResult> {
  const currentUser = get(user)
  if (!currentUser) throw { code: '42501' }
  const identity = identityGeneration
  const { data: result, error } = await sessionRpc('create_poll', operation)
  if (identity !== identityGeneration || get(user)?.id !== currentUser.id) throw { code: 'ACCOUNT_CHANGED' }
  if (error) throw error
  if (!isCreationResult(result) || result.poll.creator_id !== currentUser.id || result.poll.max_participants < 1
      || result.time_options.length !== operation.payload.time_options.length
      || result.time_options.some(option => option.poll_id !== result.poll.id)) {
    throw new Error('Creation result could not be confirmed')
  }
  // Apply returned caps and premium state, never a local entitlement estimate.
  // A list requested before creation may contain a pre-commit snapshot.
  listGeneration++
  pollsLoading.set(false)
  const starts = result.time_options.map(option => option.start_time).sort((a, b) => Date.parse(a) - Date.parse(b))
  const listed = get(createdPolls).some(row => row.id === result.poll.id)
  createdPolls.update(rows => [result.poll, ...rows.filter(row => row.id !== result.poll.id)])
  polls.update(rows => [result.poll, ...rows.filter(row => row.id !== result.poll.id)])
  // The creator is not a participant until they join.
  pollSummaries.update(map => ({ ...map, [result.poll.id]: {
    participant_count: map[result.poll.id]?.participant_count ?? 0, time_option_count: starts.length,
    earliest_start: starts[0] ?? null, latest_start: starts.at(-1) ?? null
  } }))
  if (!listed) pollListSections.update(sections => ({ ...sections, owner: { ...sections.owner, total: sections.owner.total + 1 } }))
  currentPoll.set(result.poll)
  currentPollTimeOptions.set(result.time_options)
  return result
}

// Update poll status
export async function updatePollStatus(pollId: string, status: Poll['status']) {
  detailRevision++
  const identity = identityGeneration
  const generation = loadGeneration
  const { error } = await supabase
    .from('polls')
    .update({ status })
    .abortSignal(captureSession().signal)
    .eq('id', pollId)

  if (identity !== identityGeneration || generation !== loadGeneration || get(currentPoll)?.id !== pollId) return
  if (error) {
    console.error('Failed to update poll status')
    throw error
  }

  // Update local state
  detailRevision++
  currentPoll.update(p => p ? { ...p, status } : null)
}

// Finalization returns the authoritative poll row and closes the poll atomically.
export async function setSelectedFinalDate(pollId: string, timeOptionId: string) {
  detailRevision++
  const identity = identityGeneration
  const generation = loadGeneration
  const { data, error } = await sessionRpc('finalize_poll', {
    poll_uuid: pollId, time_option_uuid: timeOptionId
  })
  if (identity !== identityGeneration || generation !== loadGeneration) return
  if (error) throw error
  // Finalizing again is allowed, so an unconfirmed result can be retried.
  if (!isPoll(data) || data.id !== pollId) throw new Error('The final time could not be confirmed. Please retry.')
  detailRevision++
  if (get(currentPoll)?.id === pollId) currentPoll.set(data)
}

// Keep the token before sending a join: a lost reply must not create another guest.
async function joinPollAsGuest(pollId: string, name?: string, email?: string): Promise<PollParticipant> {
  const existing = capabilityForPoll(pollId)
  const token = existing?.token ?? pendingGuestTokens.get(pollId)
    ?? readPendingGuestToken(browserStorage(), pollId) ?? newGuestToken()
  pendingGuestTokens.set(pollId, token)
  savePendingGuestToken(browserStorage(), pollId, token)
  const identity = identityGeneration
  const generation = loadGeneration
  const { data: result, error } = await sessionRpc('join_poll_as_guest', {
    poll_uuid: pollId, display_name: name ?? '', contact_email: email ?? null, guest_token: token
  })
  if (error) {
    if (identity === identityGeneration && generation === loadGeneration && isGuestAccessDenied(error)) {
      dropGuestCapability(pollId, token)
    }
    throw error
  }
  if (!isGuestJoinResult(result) || result.guest_token !== token || result.participant.poll_id !== pollId
      || !isValidCapability({ participantId: result.participant.id, token })) {
    throw new Error('The guest join could not be confirmed. Please retry.')
  }
  const capability = { participantId: result.participant.id, token }
  const currentToken = guestCapabilities.get(pollId)?.token ?? pendingGuestTokens.get(pollId)
  if (currentToken !== token) return result.participant
  guestCapabilities.set(pollId, capability)
  pendingGuestTokens.delete(pollId)
  clearPendingGuestToken(browserStorage(), pollId)
  saveGuestCapability(browserStorage(), pollId, capability)
  if (identity === identityGeneration && generation === loadGeneration) {
    guestNotice.set(null)
    currentGuest.set(capability)
  }
  return result.participant
}

export async function joinPoll(pollId: string, name?: string, email?: string): Promise<PollParticipant> {
  try {
    if (!get(user)) return await joinPollAsGuest(pollId, name, email)
    const { data, error } = await sessionRpc('join_poll', { poll_uuid: pollId })
    if (error) throw error
    // Membership is unique, so retrying an unconfirmed join cannot add a second one.
    if (!isJoinResult(data) || data.participant.poll_id !== pollId) {
      throw new Error('The join could not be confirmed. Please retry.')
    }
    return data.participant
  } catch (error) {
    if ((error as { code?: string })?.code === 'P0003') {
      throw new Error('This poll has reached its participant limit. Ask the organizer to free a place, then retry joining.')
    }
    throw error
  }
}

function availabilityIdentity(pollId: string, participantId: string) {
  if (get(user)) return { participant_uuid: participantId }
  const guest = capabilityForPoll(pollId)
  if (!guest || guest.participantId !== participantId) {
    throw { code: '42501', message: 'Guest access denied' }
  }
  return { participant_uuid: guest.participantId, guest_token: guest.token }
}

export async function loadAvailability(pollId: string, participantId: string): Promise<AvailabilitySnapshot> {
  const identity = identityGeneration
  const generation = loadGeneration
  const requestIdentity = availabilityIdentity(pollId, participantId)
  const { data, error } = await sessionRpc('get_availability', {
    poll_uuid: pollId, ...requestIdentity
  }, detailAbort.signal)
  if (error) {
    if (identity === identityGeneration && generation === loadGeneration && requestIdentity.guest_token && isGuestAccessDenied(error)) {
      dropGuestCapability(pollId, requestIdentity.guest_token)
    }
    throw error
  }
  return checkedSnapshot(data, pollId, participantId)
}

function checkedSnapshot(data: unknown, pollId: string, participantId: string): AvailabilitySnapshot {
  if (!isAvailabilitySnapshot(data) || data.poll_id !== pollId || data.participant_id !== participantId) {
    throw new Error('The saved responses could not be confirmed. Please retry.')
  }
  return data
}

function applyAvailability(snapshot: AvailabilitySnapshot) {
  detailRevision++
  currentAvailability.set(snapshot)
  currentPollParticipants.update(participants => participants.map(participant =>
    participant.id === snapshot.participant_id ? { ...participant, comment: snapshot.comment } : participant
  ))
  currentPollResponses.update(responses => [
    ...responses.filter(response => response.participant_id !== snapshot.participant_id),
    ...snapshot.responses.map(response => ({
      ...response, participant_id: snapshot.participant_id, created_at: response.updated_at
    }))
  ])
}

async function loadCurrentAvailability(pollId: string, participantId: string, generation: number) {
  try {
    const snapshot = await loadAvailability(pollId, participantId)
    if (generation === loadGeneration) applyAvailability(snapshot)
  } catch {
    if (generation === loadGeneration) {
      availabilityLoadError.set('Could not load your saved responses. Retry before editing.')
    }
  }
}

// The complete draft and comment commit together. Never apply optimistic rows.
export async function saveAvailability(save: AvailabilitySave): Promise<AvailabilitySnapshot> {
  detailRevision++
  const identity = identityGeneration
  const generation = loadGeneration
  const requestIdentity = availabilityIdentity(save.pollId, save.participantId)
  const { data, error } = await sessionRpc('save_availability', {
    poll_uuid: save.pollId, request_id: save.requestId,
    expected_version: save.expectedVersion, responses: save.responses, comment: save.comment,
    ...requestIdentity
  })
  if (error) {
    if (identity === identityGeneration && generation === loadGeneration && requestIdentity.guest_token && isGuestAccessDenied(error)) {
      dropGuestCapability(save.pollId, requestIdentity.guest_token)
    }
    throw error
  }
  const snapshot = checkedSnapshot(data, save.pollId, save.participantId)
  if (identity === identityGeneration && generation === loadGeneration && get(currentPoll)?.id === save.pollId) applyAvailability(snapshot)
  return snapshot
}

function stopPollUpdates() {
  pollUpdates?.stop()
  pollUpdates = null
}

/** A previous route's unmount cannot clear a newer route's poll state. */
export function ownPollDetail() {
  const owner = ++detailOwner
  cleanupPollRealtime()
  return {
    load: (pollId: string) => owner === detailOwner ? loadPoll(pollId) : Promise.resolve(),
    refresh() { if (owner === detailOwner) pollUpdates?.refresh() },
    dispose() { if (owner === detailOwner) { detailOwner++; cleanupPollRealtime() } }
  }
}

// Retain the cleanup API used by route/session owners; updates now use bounded refetches.
export function cleanupPollRealtime() {
  detailAbort.abort()
  detailAbort = new AbortController()
  loadGeneration++
  requestedPollId = null
  stopPollUpdates()
  currentPoll.set(null)
  currentPollTimeOptions.set([])
  currentPollParticipants.set([])
  currentPollResponses.set([])
  currentGuest.set(null)
  guestNotice.set(null)
  currentAvailability.set(null)
  availabilityLoadError.set(null)
  pollRefreshError.set(null)
  pollsLoading.set(false)
}
