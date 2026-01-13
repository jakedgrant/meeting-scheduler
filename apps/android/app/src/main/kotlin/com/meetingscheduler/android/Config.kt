package com.meetingscheduler.android

object Config {
    // MARK: - Environment
    // Set to true to use local Supabase instance (for development with Android emulator)
    // Set to false to use production Supabase
    private const val USE_LOCAL_SUPABASE = true

    // MARK: - Supabase
    // For Android emulator: use 10.0.2.2 to access localhost on host machine
    // For physical device on same network: use your machine's IP address (e.g., "192.168.1.100")
    private const val LOCAL_SUPABASE_URL = "http://10.0.2.2:54321"
    private const val LOCAL_SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"

    private const val PROD_SUPABASE_URL = "https://jaymsvyddyvvozzrgfpg.supabase.co"
    private const val PROD_SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpheW1zdnlkZHl2dm96enJnZnBnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjY5NjE1NjMsImV4cCI6MjA4MjUzNzU2M30.2_N53weaaa0L-hZ11NXNatbhGyPWOyW57PERQDmvmTM"

    val SUPABASE_URL = if (USE_LOCAL_SUPABASE) LOCAL_SUPABASE_URL else PROD_SUPABASE_URL
    val SUPABASE_ANON_KEY = if (USE_LOCAL_SUPABASE) LOCAL_SUPABASE_ANON_KEY else PROD_SUPABASE_ANON_KEY

    // MARK: - RevenueCat
    const val REVENUE_CAT_API_KEY = "appl_IjDPPTTLISbUsrRUeNXXBGrlLMt"

    // MARK: - App
    const val APP_NAME = "Meeting Scheduler"
    const val APP_SCHEME = "meetingscheduler"
}
