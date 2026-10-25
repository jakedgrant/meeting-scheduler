package com.meetingscheduler.android.services

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.postgrest.postgrest

/**
 * Request-owned SDK view: reuse the app HTTP transport and query/error/serialization
 * implementation, but resolve its one default Authorization from the captured token.
 * Query-builder headers append to the SDK default and can produce A+B duplicates.
 * This creates no client/engine/listener; never close the delegated application client.
 */
@OptIn(io.github.jan.supabase.annotations.SupabaseInternal::class)
internal fun accountPostgrest(client: SupabaseClient, credential: String): Postgrest {
    val owner = object : SupabaseClient by client {
        override val accessToken: suspend () -> String? = { credential }
    }
    return Postgrest.create(owner, client.postgrest.config)
}
