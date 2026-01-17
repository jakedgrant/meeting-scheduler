import { writable, get } from 'svelte/store'
import { supabase, type Poll, type PollTimeOption, type PollParticipant, type AvailabilityResponse, type AvailabilityStatus } from '$lib/supabase'
import { user } from './auth'
import type { RealtimeChannel } from '@supabase/supabase-js'

// Poll stores
export const polls = writable<Poll[]>([])
export const createdPolls = writable<Poll[]>([])
export const joinedPolls = writable<Poll[]>([])
export const currentPoll = writable<Poll | null>(null)
export const currentPollTimeOptions = writable<PollTimeOption[]>([])
export const currentPollParticipants = writable<PollParticipant[]>([])
export const currentPollResponses = writable<AvailabilityResponse[]>([])
export const pollsLoading = writable(false)

let realtimeChannel: RealtimeChannel | null = null

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

  try {
    const { data, error } = await supabase.rpc('get_user_participated_polls')

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

    // Load participants with their profiles
    const { data: participants, error: partError } = await supabase
      .from('poll_participants')
      .select('*, profiles(display_name)')
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
    .select('*, profiles(display_name)')
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
      timezone: poll.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone,
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

// Set selected final date for a poll
export async function setSelectedFinalDate(pollId: string, startTime: string, endTime: string) {
  const { error } = await supabase
    .from('polls')
    .update({
      selected_start_time: startTime,
      selected_end_time: endTime
    })
    .eq('id', pollId)

  if (error) {
    console.error('Failed to set selected final date:', error)
    throw error
  }

  // Update local state
  currentPoll.update(p => p ? {
    ...p,
    selected_start_time: startTime,
    selected_end_time: endTime
  } : null)
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

// Update participant comment
export async function updateParticipantComment(participantId: string, comment: string | null) {
  const { error } = await supabase
    .from('poll_participants')
    .update({ comment })
    .eq('id', participantId)

  if (error) {
    console.error('Failed to update participant comment:', error)
    throw error
  }

  // Update local state
  currentPollParticipants.update(participants =>
    participants.map(p =>
      p.id === participantId ? { ...p, comment } : p
    )
  )
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
