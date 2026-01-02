import { writable, get } from 'svelte/store'
import { supabase, type Poll, type PollTimeOption, type PollParticipant, type AvailabilityResponse, type AvailabilityStatus } from '$lib/supabase'
import { user } from './auth'
import type { RealtimeChannel } from '@supabase/supabase-js'

// Poll stores
export const polls = writable<Poll[]>([])
export const currentPoll = writable<Poll | null>(null)
export const currentPollTimeOptions = writable<PollTimeOption[]>([])
export const currentPollParticipants = writable<PollParticipant[]>([])
export const currentPollResponses = writable<AvailabilityResponse[]>([])
export const pollsLoading = writable(false)

let realtimeChannel: RealtimeChannel | null = null

// Load user's polls
export async function loadMyPolls() {
  const currentUser = get(user)
  if (!currentUser) {
    polls.set([])
    return
  }

  pollsLoading.set(true)

  try {
    const { data, error } = await supabase
      .from('polls')
      .select('*')
      .eq('creator_id', currentUser.id)
      .order('created_at', { ascending: false })

    if (error) throw error
    polls.set(data as Poll[])
  } catch (err) {
    console.error('Failed to load polls:', err)
  } finally {
    pollsLoading.set(false)
  }
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

// Load a single poll with all related data
export async function loadPoll(pollId: string) {
  pollsLoading.set(true)

  try {
    // Load poll
    const { data: pollData, error: pollError } = await supabase
      .from('polls')
      .select('*')
      .eq('id', pollId)
      .single()

    if (pollError) throw pollError
    currentPoll.set(pollData as Poll)

    // Load time options
    const { data: timeOptions, error: timeError } = await supabase
      .from('poll_time_options')
      .select('*')
      .eq('poll_id', pollId)
      .order('start_time', { ascending: true })

    if (timeError) throw timeError
    currentPollTimeOptions.set(timeOptions as PollTimeOption[])

    // Load participants
    const { data: participants, error: partError } = await supabase
      .from('poll_participants')
      .select('*')
      .eq('poll_id', pollId)

    if (partError) throw partError
    currentPollParticipants.set(participants as PollParticipant[])

    // Load responses
    const participantIds = participants.map(p => p.id)
    if (participantIds.length > 0) {
      const { data: responses, error: respError } = await supabase
        .from('availability_responses')
        .select('*')
        .in('participant_id', participantIds)

      if (respError) throw respError
      currentPollResponses.set(responses as AvailabilityResponse[])
    } else {
      currentPollResponses.set([])
    }

    // Set up realtime subscription
    setupRealtimeForPoll(pollId)

  } catch (err) {
    console.error('Failed to load poll:', err)
    currentPoll.set(null)
  } finally {
    pollsLoading.set(false)
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
  const { data, error } = await supabase
    .from('poll_participants')
    .select('*')
    .eq('poll_id', pollId)

  if (!error && data) {
    currentPollParticipants.set(data as PollParticipant[])
  }
}

async function loadPollResponses(pollId: string) {
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

  if (!error && data) {
    currentPollResponses.set(data as AvailabilityResponse[])
  }
}

// Create a new poll
export async function createPoll(poll: {
  title: string
  description?: string
  location?: string
  timezone?: string
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
      timezone: poll.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone
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

// Join a poll as a participant
export async function joinPoll(pollId: string, name?: string, email?: string): Promise<PollParticipant | null> {
  const currentUser = get(user)

  const participantData: Record<string, unknown> = {
    poll_id: pollId
  }

  if (currentUser) {
    participantData.user_id = currentUser.id
  } else {
    participantData.anonymous_name = name
    participantData.anonymous_email = email
  }

  const { data, error } = await supabase
    .from('poll_participants')
    .insert(participantData)
    .select()
    .single()

  if (error) {
    console.error('Failed to join poll:', error)
    throw error
  }

  return data as PollParticipant
}

// Submit availability response
export async function submitAvailability(
  participantId: string,
  timeOptionId: string,
  status: AvailabilityStatus,
  note?: string
) {
  const { error } = await supabase
    .from('availability_responses')
    .upsert({
      participant_id: participantId,
      time_option_id: timeOptionId,
      status,
      note
    }, { onConflict: 'participant_id,time_option_id' })

  if (error) {
    console.error('Failed to submit availability:', error)
    throw error
  }
}

// Clean up realtime subscription
export function cleanupPollRealtime() {
  if (realtimeChannel) {
    supabase.removeChannel(realtimeChannel)
    realtimeChannel = null
  }
  currentPoll.set(null)
  currentPollTimeOptions.set([])
  currentPollParticipants.set([])
  currentPollResponses.set([])
}
