package com.meetingscheduler.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.meetingscheduler.android.ui.ScreenModelViewModel
import com.meetingscheduler.android.ui.SessionViewModelStores
import kotlinx.coroutines.awaitCancellation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * F13 against a real Activity: the session store and a screen model held in it survive
 * configuration recreation with their work still running, and the work ends once the session's
 * identity generation changes. Offline; no account is used.
 */
@RunWith(AndroidJUnit4::class)
class ScreenModelRecreationTest {
    @Test fun screenModelAndItsWorkSurviveRecreationAndEndWithTheSession() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext.applicationContext as MeetingSchedulerApplication
        val auth = app.container.authService
        val opened = AtomicInteger()
        val working = AtomicBoolean()
        val factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = ScreenModelViewModel(
                open = { opened.incrementAndGet() },
                start = {
                    working.set(true)
                    try { awaitCancellation() } finally { working.set(false) }
                },
            ) as T
        }
        fun sessionStores(activity: MainActivity) = ViewModelProvider(
            activity, SessionViewModelStores.Factory { auth.identityGeneration },
        )[SessionViewModelStores::class.java]

        lateinit var stores: SessionViewModelStores
        lateinit var screen: ScreenModelViewModel<*>
        var generation = 0L
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            // The first provider status bumps the identity generation, which would clear the store
            // this test is about to fill, so wait for auth to finish initializing first.
            val deadline = System.nanoTime() + 30_000_000_000L
            var loading = true
            while (loading && System.nanoTime() < deadline) {
                instrumentation.runOnMainSync { loading = auth.isLoading }
                if (loading) Thread.sleep(50)
            }
            assertFalse("auth did not finish initializing", loading)
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                // The composition created this store; the provider returns that instance.
                stores = sessionStores(activity)
                generation = auth.identityGeneration
                screen = ViewModelProvider(stores.storeOwnerFor(generation).viewModelStore, factory)[ScreenModelViewModel::class.java]
                assertEquals(1, opened.get()); assertTrue(working.get())
            }

            scenario.recreate()
            instrumentation.waitForIdleSync()
            scenario.onActivity { activity ->
                assertSame(stores, sessionStores(activity))
                val again = ViewModelProvider(stores.storeOwnerFor(generation).viewModelStore, factory)[ScreenModelViewModel::class.java]
                assertSame(screen, again)
                assertEquals(1, opened.get()); assertTrue(working.get())
            }

            // A new identity generation clears the previous session's store and cancels its work.
            scenario.onActivity { stores.storeOwnerFor(generation + 1) }
            instrumentation.waitForIdleSync()
            scenario.onActivity { assertFalse(working.get()) }
        }
    }
}
