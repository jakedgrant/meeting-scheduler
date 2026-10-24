package com.meetingscheduler.android.services

import com.meetingscheduler.android.Config
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.functions.Functions
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime

object SupabaseService {
    val client: SupabaseClient = createSupabaseClient(
        supabaseUrl = Config.SUPABASE_URL,
        supabaseKey = Config.SUPABASE_ANON_KEY
    ) {
        install(Auth) {
            sessionManager = AtomicSessionManager("sb-${Config.SUPABASE_URL.removeSuffix("/").replace('/', '-').replace('.', '-')}-session")
            // SDK refresh jobs and application-owned installs share Main confinement.
            coroutineDispatcher = kotlinx.coroutines.Dispatchers.Main.immediate
            scheme = "meetingscheduler"
            host = "auth"
            defaultRedirectUrl = AUTH_REDIRECT_URL
            flowType = io.github.jan.supabase.auth.FlowType.PKCE
        }
        install(Postgrest)
        install(Realtime)
        install(Functions)
    }
}
