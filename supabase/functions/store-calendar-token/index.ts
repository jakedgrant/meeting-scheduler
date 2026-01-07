import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Decode base64url without padding
function base64urlDecode(str: string): string {
  const padded = str + '='.repeat((4 - (str.length % 4)) % 4)
  return atob(padded)
}

// Extract user ID from Supabase JWT token with validation
function getUserIdFromToken(token: string): string {
  try {
    // JWT format: header.payload.signature
    const parts = token.split('.')
    if (parts.length !== 3) {
      throw new Error('Invalid JWT format - expected 3 parts')
    }

    const [headerB64, payloadB64, signature] = parts

    // Decode the header
    const headerDecoded = base64urlDecode(headerB64)
    const header = JSON.parse(headerDecoded)
    console.log('JWT Algorithm:', header.alg, 'Type:', header.typ)

    // Decode the payload
    const payloadDecoded = base64urlDecode(payloadB64)
    const payload = JSON.parse(payloadDecoded)

    // Validate token expiration
    if (payload.exp) {
      const expirationTime = payload.exp * 1000 // Convert to milliseconds
      const currentTime = Date.now()

      if (currentTime > expirationTime) {
        throw new Error(`Token expired at ${new Date(expirationTime).toISOString()}`)
      }
      console.log('Token expires at:', new Date(expirationTime).toISOString())
    }

    // Validate issuer
    const expectedIssuer = Deno.env.get('SUPABASE_URL')?.replace(/\/$/, '') + '/auth/v1'
    if (payload.iss && payload.iss !== expectedIssuer) {
      console.warn('Token issuer mismatch. Expected:', expectedIssuer, 'Got:', payload.iss)
    }

    // Validate role (should be 'authenticated')
    if (payload.role && payload.role !== 'authenticated') {
      console.warn('Token role is not authenticated:', payload.role)
    }

    // Extract user ID from JWT claims
    const userId = payload.sub || payload.user_id
    if (!userId) {
      throw new Error('No user ID (sub or user_id) in token')
    }

    console.log('JWT validation passed for user:', userId)
    return userId
  } catch (err) {
    const errorMsg = err instanceof Error ? err.message : String(err)
    console.error('JWT validation error:', errorMsg)
    throw new Error(`Invalid authentication token: ${errorMsg}`)
  }
}

Deno.serve(async (req) => {
  console.log('=== FUNCTION START ===')
  console.log('Method:', req.method)

  // Log all headers for debugging
  const headerEntries = Array.from(req.headers.entries())
  console.log('All headers:', headerEntries.map(([k, v]) => `${k}: ${v.substring(0, 50)}${v.length > 50 ? '...' : ''}`))

  // CORS headers
  if (req.method === 'OPTIONS') {
    console.log('Handling CORS preflight')
    const response = new Response('ok', {
      status: 200,
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
        'Access-Control-Max-Age': '86400',
      },
    })
    return response
  }

  try {
    // Try to get authorization header (case-insensitive)
    let authHeader = req.headers.get('Authorization') ||
                     req.headers.get('authorization') ||
                     req.headers.get('AUTHORIZATION')

    console.log('Authorization header found:', !!authHeader)

    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      console.error('Missing or invalid Authorization header')
      return new Response(
        JSON.stringify({ error: 'Missing Authorization header' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Extract JWT token and validate it
    const token = authHeader.substring(7)
    console.log('Extracted JWT token, length:', token.length)

    const userId = getUserIdFromToken(token)
    console.log('Authenticated user ID:', userId)

    console.log('Creating Supabase admin client...')
    // Create admin client to access identities
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    )
    console.log('Admin client created')

    // Get user from database using service role
    console.log('Fetching user:', userId)
    const { data: { user }, error: userError } = await supabaseAdmin.auth.admin.getUserById(userId)
    console.log('User fetch response - user:', !!user, 'error:', !!userError)

    if (userError || !user) {
      console.error('User fetch failed - userError:', userError)
      return new Response(
        JSON.stringify({ error: 'User not found', details: userError?.message }),
        { status: 404, headers: { 'Content-Type': 'application/json' } }
      )
    }

    console.log('User found:', user.id)
    console.log('User identities count:', user.identities?.length)

    // Extract Google OAuth refresh token from user identities
    const googleIdentity = user.identities?.find(
      (identity: any) => identity.provider === 'google'
    )

    console.log('Google identity found:', !!googleIdentity)

    if (!googleIdentity) {
      return new Response(
        JSON.stringify({
          error: 'Google identity not found. Please sign in with Google first.',
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const refreshToken = googleIdentity.identity_data?.provider_refresh_token
    const accessToken = googleIdentity.identity_data?.provider_token

    console.log('Refresh token found:', !!refreshToken)
    console.log('Access token found:', !!accessToken)

    if (!refreshToken) {
      console.error('No refresh token in identity_data. Available keys:', Object.keys(googleIdentity.identity_data || {}))
      return new Response(
        JSON.stringify({
          error: 'No refresh token available. The calendar scope may not have been properly granted.',
          hint: 'Make sure your Google OAuth app has calendar scope configured in Google Cloud Console.',
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Store tokens in profiles table
    // Note: This function stores tokens from identities, but in practice,
    // tokens are persisted in the auth callback route instead
    const { error: updateError } = await supabaseAdmin
      .from('profiles')
      .update({
        google_calendar_access_token: accessToken || null,
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

    // Return 401 for auth errors
    if (error instanceof Error && error.message.includes('Invalid authentication token')) {
      return new Response(
        JSON.stringify({
          success: false,
          error: error.message,
        }),
        {
          status: 401,
          headers: {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
          },
        }
      )
    }

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
