import { writable, get } from 'svelte/store'
import { supabase, type Poll, type PollTimeOption, type PollParticipant, type AvailabilityResponse } from '$lib/supabase'
import { user } from './auth'
import type { RealtimeChannel } from '@supabase/supabase-js'
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
  type GuestCapability
} from '$lib/guest-capability'
import type { AvailabilitySave, AvailabilitySnapshot } from '$lib/availability-editor'

// Poll stores
export const polls = writable<Poll[]>([])
export const createdPolls = writable<Poll[]>([])
export const joinedPolls = writable<Poll[]>([])
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

const guestCapabilities = new Map<string, GuestCapability>()
const pendingGuestTokens = new Map<string, string>()
let realtimeChannel: RealtimeChannel | null = null
let loadGeneration = 0
let requestedPollId: string | null = null
let identityGeneration = 0
let lastUserId: string | null = null

// Invalidate in-flight reads and current detail at every account transition.
user.subscribe(value => {
  const userId = value?.id ?? null
  if (userId === lastUserId) return
  lastUserId = userId
  identityGeneration++
  cleanupPollRealtime()
  polls.set([])
  createdPolls.set([])
  joinedPolls.set([])
})

function capabilityForPoll(pollId: string) {
  const capability = guestCapabilities.get(pollId) ?? readGuestCapability(browserStorage(), pollId)
  if (capability) guestCapabilities.set(pollId, capability)
  return capability ?? null
}

// Load user's polls (both created and participated)
export async function loadParticipatedPolls() {
  const currentUser = get(user)
  if (!currentUser) {
    createdPolls.set([])
    joinedPolls.set([])
    polls.set([])
    return
  }

  pollsLoading.set(true)
  const identity = identityGeneration

  try {
    const { data, error } = await supabase.rpc('get_user_participated_polls')

    if (identity !== identityGeneration) return
    if (error) throw error

    const created = data?.created_polls || []
    const joined = data?.joined_polls || []

    createdPolls.set(created as Poll[])
    joinedPolls.set(joined as Poll[])
    polls.set([...(created as Poll[]), ...(joined as Poll[])])
  } catch (err) {
    console.error('Failed to load polls:', err)
  } finally {
    pollsLoading.set(false)
  }
}

// Legacy function for backward compatibility
export async function loadMyPolls() {
  return loadParticipatedPolls()
}

// Load a poll by share code
export async function loadPollByCode(code: string): Promise<Poll | null> {
  try {
    const { data, error } = await supabase.rpc('get_poll_by_code', { code: code.toUpperCase() })

    if (error) throw error
    if (!data || data.length === 0) return null

    return data[0] as Poll
  } catch (err) {
    console.error('Failed to load poll by code:', err)
    return null
  }
}

interface GuestPollDetail {
  participant_id: string
  poll: Poll
  time_options: PollTimeOption[]
  participants: PollParticipant[]
  responses: AvailabilityResponse[]
}

function dropGuestCapability(pollId: string) {
  guestCapabilities.delete(pollId)
  pendingGuestTokens.delete(pollId)
  clearGuestCapability(browserStorage(), pollId)
  clearPendingGuestToken(browserStorage(), pollId)
  if (requestedPollId === pollId) {
    currentGuest.set(null)
    guestNotice.set(GUEST_ACCESS_LOST_MESSAGE)
  }
}

// Signed-out guests cannot read participant rows; they load the poll through
// their capability. Returns false when the caller should use the normal path.
async function loadGuestPoll(pollId: string, guest: GuestCapability, generation: number): Promise<boolean> {
  const { data, error } = await supabase.rpc('get_guest_poll_detail', {
    participant_uuid: guest.participantId,
    guest_token: guest.token
  })
  if (generation !== loadGeneration) return true
  if (error) {
    if (isGuestAccessDenied(error)) {
      dropGuestCapability(pollId)
      return false
    }
    throw error
  }
  const detail = data as GuestPollDetail
  if (!detail?.poll || detail.poll.id !== pollId) {
    dropGuestCapability(pollId)
    return false
  }
  currentGuest.set(guest)
  currentPoll.set(detail.poll)
  currentPollTimeOptions.set(detail.time_options)
  currentPollParticipants.set(detail.participants)
  currentPollResponses.set(detail.responses)
  await loadCurrentAvailability(pollId, detail.participant_id, generation)
  if (generation !== loadGeneration) return true
  // Guests receive no participant/response Realtime events; they refresh on load and after saves.
  if (realtimeChannel) {
    supabase.removeChannel(realtimeChannel)
    realtimeChannel = null
  }
  return true
}

// Load a single poll with all related data
export async function loadPoll(pollId: string) {
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
    if (guest && await loadGuestPoll(pollId, guest, generation)) return

    // Load poll
    const { data: pollData, error: pollError } = await supabase
      .from('polls')
      .select('*')
      .eq('id', pollId)
      .single()

    if (generation !== loadGeneration) return
    if (pollError) throw pollError
    currentPoll.set(pollData as Poll)

    // Load time options
    const { data: timeOptions, error: timeError } = await supabase
      .from('poll_time_options')
      .select('*')
      .eq('poll_id', pollId)
      .order('start_time', { ascending: true })

    if (generation !== loadGeneration) return
    if (timeError) throw timeError
    currentPollTimeOptions.set(timeOptions as PollTimeOption[])

    // Load participants with their profiles
    const { data: participants, error: partError } = await supabase
      .from('poll_participants')
      .select('*, profiles(display_name)')
      .eq('poll_id', pollId)

    if (generation !== loadGeneration) return
    if (partError) throw partError
    currentPollParticipants.set(participants as PollParticipant[])

    // Load responses
    const participantIds = participants.map(p => p.id)
    if (participantIds.length > 0) {
      const { data: responses, error: respError } = await supabase
        .from('availability_responses')
        .select('*')
        .in('participant_id', participantIds)

      if (generation !== loadGeneration) return
      if (respError) throw respError
      currentPollResponses.set(responses as AvailabilityResponse[])
    } else {
      currentPollResponses.set([])
    }

    const ownParticipant = (participants as PollParticipant[]).find(participant => participant.user_id === get(user)?.id)
    if (ownParticipant) await loadCurrentAvailability(pollId, ownParticipant.id, generation)
    else currentAvailability.set(null)
    if (generation !== loadGeneration) return

    // Set up realtime subscription
    setupRealtimeForPoll(pollId)

  } catch (err) {
    if (generation !== loadGeneration) return
    console.error('Failed to load poll')
    currentPoll.set(null)
  } finally {
    if (generation === loadGeneration) pollsLoading.set(false)
  }
}

// Set up realtime updates for a poll
function setupRealtimeForPoll(pollId: string) {
  // Clean up existing subscription
  if (realtimeChannel) {
    supabase.removeChannel(realtimeChannel)
  }

  realtimeChannel = supabase
    .channel(`poll-${pollId}`)
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'poll_participants',
        filter: `poll_id=eq.${pollId}`
      },
      () => {
        // Reload participants when changes occur
        loadPollParticipants(pollId)
      }
    )
    .on(
      'postgres_changes',
      {
        event: '*',
        schema: 'public',
        table: 'availability_responses'
      },
      () => {
        // Reload responses when changes occur
        loadPollResponses(pollId)
      }
    )
    .subscribe()
}

async function loadPollParticipants(pollId: string) {
  const generation = loadGeneration
  const { data, error } = await supabase
    .from('poll_participants')
    .select('*, profiles(display_name)')
    .eq('poll_id', pollId)

  if (generation === loadGeneration && get(currentPoll)?.id === pollId && !error && data) {
    currentPollParticipants.set(data as PollParticipant[])
  }
}

async function loadPollResponses(pollId: string) {
  const generation = loadGeneration
  const participants = get(currentPollParticipants)
  const participantIds = participants.map(p => p.id)

  if (participantIds.length === 0) {
    currentPollResponses.set([])
    return
  }

  const { data, error } = await supabase
    .from('availability_responses')
    .select('*')
    .in('participant_id', participantIds)

  if (generation === loadGeneration && get(currentPoll)?.id === pollId && !error && data) {
    currentPollResponses.set(data as AvailabilityResponse[])
  }
}

// Create a new poll
export async function createPoll(poll: {
  title: string
  description?: string
  location?: string
  timezone?: string
  closesAt?: string
}): Promise<Poll | null> {
  const currentUser = get(user)
  if (!currentUser) return null

  const { data, error } = await supabase
    .from('polls')
    .insert({
      creator_id: currentUser.id,
      title: poll.title,
      description: poll.description,
      location: poll.location,
      timezone: poll.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,
      closes_at: poll.closesAt,
      status: 'active'
    })
    .select()
    .single()

  if (error) {
    console.error('Failed to create poll:', error)
    throw error
  }

  return data as Poll
}

// Add time options to a poll
export async function addTimeOptions(pollId: string, options: Array<{
  start_time: string
  end_time: string
  is_all_day?: boolean
}>): Promise<PollTimeOption[]> {
  const { data, error } = await supabase
    .from('poll_time_options')
    .insert(options.map(opt => ({
      poll_id: pollId,
      start_time: opt.start_time,
      end_time: opt.end_time,
      is_all_day: opt.is_all_day ?? false
    })))
    .select()

  if (error) {
    console.error('Failed to add time options:', error)
    throw error
  }

  return data as PollTimeOption[]
}

// Update poll status
export async function updatePollStatus(pollId: string, status: Poll['status']) {
  const { error } = await supabase
    .from('polls')
    .update({ status })
    .eq('id', pollId)

  if (error) {
    console.error('Failed to update poll status:', error)
    throw error
  }

  // Update local state
  currentPoll.update(p => p ? { ...p, status } : null)
}

// Finalization returns the authoritative poll row and closes the poll atomically.
export async function setSelectedFinalDate(pollId: string, timeOptionId: string) {
  const identity = identityGeneration
  const generation = loadGeneration
  const { data, error } = await supabase.rpc('finalize_poll', {
    poll_uuid: pollId, time_option_uuid: timeOptionId
  })
  if (error) throw error
  if (identity === identityGeneration && generation === loadGeneration && get(currentPoll)?.id === pollId) currentPoll.set(data as Poll)
}

// Keep the token before sending a join: a lost reply must not create another guest.
async function joinPollAsGuest(pollId: string, name?: string, email?: string): Promise<PollParticipant> {
  const existing = capabilityForPoll(pollId)
  const token = existing?.token ?? pendingGuestTokens.get(pollId)
    ?? readPendingGuestToken(browserStorage(), pollId) ?? newGuestToken()
  pendingGuestTokens.set(pollId, token)
  savePendingGuestToken(browserStorage(), pollId, token)
  const identity = identityGeneration
  const { data, error } = await supabase.rpc('join_poll_as_guest', {
    poll_uuid: pollId, display_name: name ?? '', contact_email: email ?? null, guest_token: token
  })
  if (error) {
    if (isGuestAccessDenied(error)) dropGuestCapability(pollId)
    throw error
  }
  const result = data as { participant: PollParticipant; guest_token: string }
  const capability = { participantId: result?.participant?.id, token: result?.guest_token }
  if (!isValidCapability(capability) || capability.token !== token || result.participant.poll_id !== pollId) {
    throw new Error('The guest join could not be confirmed. Please retry.')
  }
  guestCapabilities.set(pollId, capability)
  pendingGuestTokens.delete(pollId)
  clearPendingGuestToken(browserStorage(), pollId)
  saveGuestCapability(browserStorage(), pollId, capability)
  if (identity === identityGeneration) {
    guestNotice.set(null)
    currentGuest.set(capability)
  }
  return result.participant
}

export async function joinPoll(pollId: string, name?: string, email?: string): Promise<PollParticipant> {
  if (!get(user)) return joinPollAsGuest(pollId, name, email)
  const { data, error } = await supabase.rpc('join_poll', { poll_uuid: pollId })
  if (error) throw error
  return (data as { participant: PollParticipant }).participant
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
  const { data, error } = await supabase.rpc('get_availability', {
    poll_uuid: pollId, ...availabilityIdentity(pollId, participantId)
  })
  if (error) {
    if (isGuestAccessDenied(error)) dropGuestCapability(pollId)
    throw error
  }
  return checkedSnapshot(data, pollId, participantId)
}

function checkedSnapshot(data: unknown, pollId: string, participantId: string): AvailabilitySnapshot {
  const snapshot = data as AvailabilitySnapshot
  if (!snapshot || snapshot.poll_id !== pollId || snapshot.participant_id !== participantId
      || !Number.isSafeInteger(snapshot.version) || !Array.isArray(snapshot.responses)) {
    throw new Error('The saved responses could not be confirmed. Please retry.')
  }
  return snapshot
}

function applyAvailability(snapshot: AvailabilitySnapshot) {
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
  const identity = identityGeneration
  const generation = loadGeneration
  const { data, error } = await supabase.rpc('save_availability', {
    poll_uuid: save.pollId, request_id: save.requestId,
    expected_version: save.expectedVersion, responses: save.responses, comment: save.comment,
    ...availabilityIdentity(save.pollId, save.participantId)
  })
  if (error) {
    if (isGuestAccessDenied(error)) dropGuestCapability(save.pollId)
    throw error
  }
  const snapshot = checkedSnapshot(data, save.pollId, save.participantId)
  if (identity === identityGeneration && generation === loadGeneration && get(currentPoll)?.id === save.pollId) applyAvailability(snapshot)
  return snapshot
}

// Clean up realtime subscription
export function cleanupPollRealtime() {
  loadGeneration++
  requestedPollId = null
  if (realtimeChannel) {
    supabase.removeChannel(realtimeChannel)
    realtimeChannel = null
  }
  currentPoll.set(null)
  currentPollTimeOptions.set([])
  currentPollParticipants.set([])
  currentPollResponses.set([])
  currentGuest.set(null)
  guestNotice.set(null)
  currentAvailability.set(null)
  availabilityLoadError.set(null)
  pollsLoading.set(false)
}
