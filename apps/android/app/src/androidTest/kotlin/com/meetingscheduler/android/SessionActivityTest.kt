package com.meetingscheduler.android

import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.authRedirectUrl
import io.github.jan.supabase.auth.auth
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Offline OS/Activity integration. No provider session or account is used. */
@RunWith(AndroidJUnit4::class)
class SessionActivityTest {
    @Test fun sdkRefreshPreservesAttemptButFreshSameAccountSessionInvalidatesIt() = kotlinx.coroutines.runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val app = context.applicationContext as MeetingSchedulerApplication
        val auth = app.container.authService
        val sdk = com.meetingscheduler.android.services.SupabaseService.client
        fun session(lineage: String, revision: Int): io.github.jan.supabase.auth.user.UserSession {
            val encoder = java.util.Base64.getUrlEncoder().withoutPadding()
            fun encode(value: String) = encoder.encodeToString(value.toByteArray())
            val payload = encode("{\"session_id\":\"$lineage\",\"revision\":$revision}")
            val token = "${encode("{\"alg\":\"HS256\"}")}.$payload.signature"
            return kotlinx.serialization.json.Json { ignoreUnknownKeys = true }.decodeFromString("""{"access_token":"$token","refresh_token":"synthetic-$lineage","expires_in":3600,"token_type":"bearer","user":{"id":"a0000000-0000-0000-0000-000000000001","aud":"authenticated"}}""")
        }
        var generation = 0L
        lateinit var old: String
        try {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { sdk.auth.importSession(session("old-server-session", 1), autoRefresh = false) }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync { generation = auth.identityGeneration; old = auth.callbackRouter.beginFlow() }
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { sdk.auth.importSession(session("old-server-session", 2), autoRefresh = false) }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync { assertEquals(generation, auth.identityGeneration); assertEquals(old, auth.callbackRouter.pendingAttemptId) }
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) { sdk.auth.importSession(session("new-server-session", 1), autoRefresh = false) }
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                assertTrue(auth.identityGeneration > generation); assertNull(auth.callbackRouter.pendingAttemptId)
                val current = auth.callbackRouter.beginFlow()
                auth.handleDeepLink(authRedirectUrl(old) + "&code=obsolete-synthetic-code")
                auth.handleDeepLink(authRedirectUrl(old) + "&error=access_denied")
                assertEquals(current, auth.callbackRouter.pendingAttemptId); assertNull(auth.callbackError)
            }
        } finally {
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main.immediate) {
                sdk.auth.stopAutoRefreshForCurrentSession(); sdk.auth.clearSession()
            }
            instrumentation.waitForIdleSync()
        }
    }


    @Test fun warmAuthCallbackSurvivesRecreationAndCalendarRouteDoesNotEnterAuth() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        lateinit var auth: AuthService
        lateinit var attempt: String
        lateinit var obsolete: String
        val launchIntent = Intent(context, MainActivity::class.java)
        ActivityScenario.launch<MainActivity>(launchIntent).use { scenario ->
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                auth = (activity.application as MeetingSchedulerApplication).container.authService
                assertFalse(auth.isAuthenticated)
                obsolete = auth.callbackRouter.beginFlow()
                attempt = auth.callbackRouter.beginFlow()
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                assertSame(auth, (activity.application as MeetingSchedulerApplication).container.authService)
                activity.startActivity(Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).setData(Uri.parse(authRedirectUrl(obsolete) + "&error=access_denied")))
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                assertNull(auth.callbackError)
                assertEquals(attempt, auth.callbackRouter.pendingAttemptId)
                auth.callbackRouter.route(authRedirectUrl(attempt) + "&code=")
                activity.startActivity(Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).setData(Uri.parse("meetingscheduler://calendar/callback?error=access_denied")))
                assertTrue(auth.callbackError!!.contains("could not be completed"))
                activity.startActivity(Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).setData(Uri.parse("meetingscheduler://auth/other?error=access_denied")))
                assertTrue(auth.callbackError!!.contains("could not be completed"))
                activity.startActivity(Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).setData(Uri.parse(authRedirectUrl(attempt) + "&error=access_denied")))
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                assertTrue(auth.callbackError!!.contains("cancelled")); assertFalse(auth.isAuthenticated)
                activity.intent = launchIntent // ActivityScenario matches cleanup by its original intent.
            }
        }
    }

    @Test fun launchIntentUsesSameRouterAndDuplicateDeliveryHasNoExtraEffect() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val app = context.applicationContext as MeetingSchedulerApplication
        lateinit var attempt: String
        instrumentation.runOnMainSync { attempt = app.container.authService.callbackRouter.beginFlow() }
        val link = authRedirectUrl(attempt) + "&error=access_denied&description=cold-runtime"
        val launchIntent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse(link))
        ActivityScenario.launch<MainActivity>(launchIntent).use { scenario ->
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                val auth = app.container.authService
                assertTrue(auth.callbackError!!.contains("cancelled"))
                val before = auth.callbackError
                activity.startActivity(Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).setData(Uri.parse(link)))
                assertEquals(before, auth.callbackError)
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity { it.intent = launchIntent }
        }
    }
}
