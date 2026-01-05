import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

interface TimeOption {
  id: string
  start_time: string
  end_time: string
}

interface RequestBody {
  userId: string
  timeOptions: TimeOption[]
}

// Get Google Calendar access token for the user
async function getAccessToken(
  userId: string,
  supabase: any
): Promise<string> {
  const { data: profile, error: fetchError } = await supabase
    .from('profiles')
    .select('google_calendar_access_token, google_calendar_token_expires_at')
    .eq('id', userId)
    .single()

  if (fetchError || !profile?.google_calendar_access_token) {
    throw new Error('No calendar access token found')
  }

  const now = new Date()
  const expiresAt = new Date(profile.google_calendar_token_expires_at)

  // Token still valid
  if (expiresAt > now) {
    console.log('Using stored access token for user:', userId)
    return profile.google_calendar_access_token
  }

  // Token expired - user needs to re-authenticate
  throw new Error('Calendar access token expired. Please re-authenticate in settings.')
}

interface GoogleCalendarEvent {
  id: string
  start: { dateTime?: string; date?: string }
  end: { dateTime?: string; date?: string }
  transparency?: string
  status?: string
  attendees?: Array<{ self: boolean; responseStatus: string }>
}

// Check for conflicts with Google Calendar events
async function checkSingleConflict(
  accessToken: string,
  startTime: string,
  endTime: string
): Promise<boolean> {
  const start = new Date(startTime)
  const end = new Date(endTime)

  const params = new URLSearchParams({
    timeMin: start.toISOString(),
    timeMax: end.toISOString(),
    singleEvents: 'true',
    maxResults: '10',
  })

  const response = await fetch(
    `https://www.googleapis.com/calendar/v3/calendars/primary/events?${params}`,
    {
      headers: { Authorization: `Bearer ${accessToken}` },
    }
  )

  if (!response.ok) {
    if (response.status === 401) {
      throw new Error('Unauthorized: Token expired or invalid')
    }
    throw new Error(
      `Google Calendar API error: ${response.status} ${response.statusText}`
    )
  }

  const data = await response.json()
  const events = data.items || []

  // Filter out events that don't count as busy:
  // - Cancelled events
  // - Transparent events (don't block time)
  // - Events where user declined
  const busyEvents = events.filter((event: GoogleCalendarEvent) => {
    // Skip cancelled events
    if (event.status === 'cancelled') return false

    // Skip transparent events (don't block time)
    if (event.transparency === 'transparent') return false

    // Skip if user has declined
    if (event.attendees?.some((att) => att.self && att.responseStatus === 'declined')) {
      return false
    }

    return true
  })

  return busyEvents.length > 0
}

Deno.serve(async (req) => {
  // CORS headers
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
      },
    })
  }

  try {
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    // Parse request body
    const body: RequestBody = await req.json()
    const { userId, timeOptions } = body

    if (!userId) {
      return new Response(
        JSON.stringify({ error: 'Missing userId in request body' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    if (!Array.isArray(timeOptions) || timeOptions.length === 0) {
      return new Response(
        JSON.stringify({
          error: 'Invalid request: timeOptions must be a non-empty array',
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get access token (refresh if needed)
    const accessToken = await getAccessToken(userId, supabaseAdmin)

    // Check conflicts for each time option
    const conflictingIds: string[] = []

    for (const option of timeOptions) {
      try {
        const hasConflict = await checkSingleConflict(
          accessToken,
          option.start_time,
          option.end_time
        )

        if (hasConflict) {
          conflictingIds.push(option.id)
        }
      } catch (error) {
        // Log but don't fail the whole request
        console.error(
          `Error checking conflict for option ${option.id}:`,
          error instanceof Error ? error.message : String(error)
        )
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        conflictingIds,
      }),
      {
        status: 200,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    )
  } catch (error) {
    console.error('Function error:', error)

    // Return empty conflicts on error (fail gracefully)
    return new Response(
      JSON.stringify({
        success: false,
        error: error instanceof Error ? error.message : 'Unknown error',
        conflictingIds: [], // Return empty to not block user
      }),
      {
        status: 200, // Return 200 with empty conflicts so frontend doesn't treat as error
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    )
  }
})
