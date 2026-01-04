import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

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
    // Create admin client to access identities
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )

    // Get user from Authorization header
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Missing authorization header' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const token = authHeader.replace('Bearer ', '')

    // Get user from JWT
    const { data: { user }, error: userError } = await supabaseAdmin.auth.getUser(token)

    if (userError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized', details: userError?.message }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Extract Google OAuth refresh token from user identities
    const googleIdentity = user.identities?.find(
      (identity: any) => identity.provider === 'google'
    )

    if (!googleIdentity) {
      return new Response(
        JSON.stringify({
          error: 'Google identity not found. Please sign in with Google first.',
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const refreshToken = googleIdentity.identity_data?.provider_refresh_token

    if (!refreshToken) {
      return new Response(
        JSON.stringify({
          error: 'No refresh token available. Please sign in again with calendar access.',
          hint: 'Make sure to grant calendar permissions during sign-in.',
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
    console.error('Function error:', error)
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
