package com.meetingscheduler.android

import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.authRedirectUrl
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Offline OS/Activity integration. No provider session or account is used. */
@RunWith(AndroidJUnit4::class)
class SessionActivityTest {
    @Test fun warmAuthCallbackSurvivesRecreationAndCalendarRouteDoesNotEnterAuth() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        lateinit var auth: AuthService
        lateinit var attempt: String
        val launchIntent = Intent(context, MainActivity::class.java)
        ActivityScenario.launch<MainActivity>(launchIntent).use { scenario ->
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                auth = (activity.application as MeetingSchedulerApplication).container.authService
                assertFalse(auth.isAuthenticated)
                val obsolete = auth.callbackRouter.beginFlow()
                attempt = auth.callbackRouter.beginFlow()
                activity.startActivity(Intent(activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).setData(Uri.parse(authRedirectUrl(obsolete) + "&error=access_denied")))
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertNull(auth.callbackError)
                assertEquals(attempt, auth.callbackRouter.pendingAttemptId)
                auth.callbackRouter.route(authRedirectUrl(attempt) + "&code=")
            }
            scenario.recreate()
            scenario.onActivity { activity ->
                assertSame(auth, (activity.application as MeetingSchedulerApplication).container.authService)
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
