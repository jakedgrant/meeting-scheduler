package com.meetingscheduler.android

import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.createSupabaseClient
import io.ktor.client.engine.mock.MockEngine

/** For services whose tests replace every request with a transport. Any request fails the test. */
fun unusedSupabaseClient(): SupabaseClient = createSupabaseClient("https://unused.invalid", "unit-key") {
    httpEngine = MockEngine { request -> error("Unexpected Supabase request: ${request.url}") }
}
