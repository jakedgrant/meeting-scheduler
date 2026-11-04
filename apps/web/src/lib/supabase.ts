import type { Enums, Tables } from './database.types'
import { browser } from '$app/environment'
import { createOwnedAuth, browserAuthStorage, memoryAuthStorage } from './owned-auth'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables')
}

export const ownedAuth = createOwnedAuth({ url: supabaseUrl, key: supabaseAnonKey,
  storage: browser ? browserAuthStorage() : memoryAuthStorage(), autoRefresh: browser })
export const supabase = ownedAuth.client

// Row types come from the migrations; see database.types.ts.
export type PollStatus = Enums<'poll_status'>
export type AvailabilityStatus = Enums<'availability_status'>
export type Profile = Tables<'profiles'>
export type Subscription = Tables<'subscriptions'>
export type Poll = Tables<'polls'>
export type PollTimeOption = Tables<'poll_time_options'>
export type AvailabilityResponse = Tables<'availability_responses'>
// get_poll_detail embeds the participant's display name.
export type PollParticipant = Tables<'poll_participants'> & {
  profiles?: { display_name: string | null } | null
}
