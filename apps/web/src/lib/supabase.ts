import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { browser } from '$app/environment'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseAnonKey) {
  throw new Error('Missing Supabase environment variables')
}

export const supabase: SupabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    persistSession: browser,
    autoRefreshToken: browser,
    detectSessionInUrl: browser
  }
})

// Database types - will be generated from Supabase
export type PollStatus = 'draft' | 'active' | 'closed' | 'archived'
export type AvailabilityStatus = 'available' | 'maybe' | 'unavailable'

export interface Profile {
  id: string
  email: string
  display_name: string | null
  avatar_url: string | null
  timezone: string
  created_at: string
  updated_at: string
}

export interface Subscription {
  id: string
  user_id: string
  revenuecat_app_user_id: string | null
  original_transaction_id: string | null
  entitlement: string | null
  is_active: boolean
  product_id: string | null
  store: string | null
  period_type: string | null
  purchased_at: string | null
  expires_at: string | null
  cancellation_at: string | null
  created_at: string
  updated_at: string
}

export interface Poll {
  id: string
  creator_id: string
  title: string
  description: string | null
  location: string | null
  status: PollStatus
  timezone: string
  is_premium: boolean
  max_participants: number
  created_at: string
  updated_at: string
  closes_at: string | null
  selected_start_time: string | null
  selected_end_time: string | null
  share_code: string
}

export interface PollTimeOption {
  id: string
  poll_id: string
  start_time: string
  end_time: string
  is_all_day: boolean
  created_at: string
}

export interface PollParticipant {
  id: string
  poll_id: string
  user_id: string | null
  anonymous_name: string | null
  anonymous_email: string | null
  access_token: string
  created_at: string
  updated_at: string
}

export interface AvailabilityResponse {
  id: string
  participant_id: string
  time_option_id: string
  status: AvailabilityStatus
  note: string | null
  created_at: string
  updated_at: string
}
