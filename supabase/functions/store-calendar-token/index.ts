import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

Deno.serve(async (req) => {
  console.log('=== FUNCTION START ===')
  console.log('Method:', req.method)
  console.log('Headers:', Object.fromEntries(req.headers.entries()))

  // CORS headers
  if (req.method === 'OPTIONS') {
    console.log('Handling CORS preflight')
    const response = new Response('ok', {
      status: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
        'Access-Control-Max-Age': '86400',
      },
    })
    console.log('Preflight response status:', response.status)
    console.log('Preflight response headers:', Object.fromEntries(response.headers.entries()))
    return response
  }

  try {
    console.log('Creating Supabase admin client...')
    // Create admin client to access identities
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )
    console.log('Admin client created')

    // Parse request body
    console.log('Parsing request body...')
    const body = await req.json()
    console.log('Body parsed:', body)

    const userId = body?.userId
    console.log('User ID from body:', userId)

    if (!userId) {
      console.log('Returning 400: Missing userId')
      return new Response(
        JSON.stringify({ error: 'Missing userId in request body' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get user from database using service role
    console.log('Fetching user:', userId)
    const { data: { user }, error: userError } = await supabaseAdmin.auth.admin.getUserById(userId)
    console.log('User fetch response - user:', !!user, 'error:', !!userError)

    if (userError || !user) {
      console.log('User fetch failed - userError:', userError)
      console.log('User object:', user)
      return new Response(
        JSON.stringify({ error: 'User not found', details: userError?.message }),
        { status: 404, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // DEBUG: Log the entire user object to see all available fields
    console.log('=== FULL USER OBJECT ===')
    console.log(JSON.stringify(user, null, 2))
    console.log('=== USER OBJECT KEYS ===')
    console.log(Object.keys(user))
    console.log('=== USER.IDENTITIES ===')
    console.log(JSON.stringify(user.identities, null, 2))

    // Extract Google OAuth refresh token from user identities
    const googleIdentity = user.identities?.find(
      (identity: any) => identity.provider === 'google'
    )

    console.log('Google identity found:', !!googleIdentity)
    console.log('Full identity data:', JSON.stringify(googleIdentity?.identity_data, null, 2))

    if (!googleIdentity) {
      return new Response(
        JSON.stringify({
          error: 'Google identity not found. Please sign in with Google first.',
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const refreshToken = googleIdentity.identity_data?.provider_refresh_token

    console.log('Refresh token found:', !!refreshToken)
    console.log('Available identity_data keys:', Object.keys(googleIdentity.identity_data || {}))

    if (!refreshToken) {
      console.error('No refresh token in identity_data. Available keys:', Object.keys(googleIdentity.identity_data || {}))
      return new Response(
        JSON.stringify({
          error: 'No refresh token available. The calendar scope may not have been properly granted.',
          available_keys: Object.keys(googleIdentity.identity_data || {}),
          hint: 'Make sure your Google OAuth app has calendar scope configured in Google Cloud Console.',
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Store encrypted refresh token in profiles table
    const { error: updateError } = await supabaseAdmin
      .from('profiles')
      .update({
        google_calendar_refresh_token: refreshToken,
        google_calendar_token_expires_at: new Date(
          Date.now() + 3600 * 1000
        ).toISOString(),
        calendar_integration_enabled: true,
      })
      .eq('id', user.id)

    if (updateError) {
      console.error('Update error:', updateError)
      return new Response(
        JSON.stringify({
          error: 'Failed to store calendar token',
          details: updateError.message,
        }),
        { status: 500, headers: { 'Content-Type': 'application/json' } }
      )
    }

    console.log('=== SUCCESS ===')
    console.log('Token stored successfully for user:', user.id)
    return new Response(
      JSON.stringify({
        success: true,
        message: 'Calendar token stored successfully',
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
    console.error('=== FUNCTION ERROR ===')
    console.error('Error type:', error?.constructor?.name)
    console.error('Error message:', error instanceof Error ? error.message : String(error))
    console.error('Full error:', error)
    return new Response(
      JSON.stringify({
        error: 'Internal server error',
        details: error instanceof Error ? error.message : String(error),
      }),
      {
        status: 500,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      }
    )
  }
})
