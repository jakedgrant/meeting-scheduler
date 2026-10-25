package com.meetingscheduler.android

import android.os.Bundle
import android.content.Intent
import kotlinx.coroutines.launch
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.meetingscheduler.android.ui.ContentView
import com.meetingscheduler.android.ui.theme.MeetingSchedulerTheme

class MainActivity : ComponentActivity() {
    // Process-lifetime services from the Application (F13). The Activity only borrows them;
    // Activity-bound work below uses lifecycleScope, which is cancelled with this instance.
    private val container: AppContainer
        get() = (application as MeetingSchedulerApplication).container

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        routeIntent(intent)

        setContent {
            MeetingSchedulerTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ContentView(
                        authService = container.authService,
                        pollService = container.pollService,
                        calendarService = container.calendarService,
                        purchaseService = container.purchaseService
                    )
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        lifecycleScope.launch { container.calendarService.refreshGoogleCalendarConnection() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeIntent(intent)
    }

    private fun routeIntent(intent: Intent?) {
        val uri = intent?.data
        if (uri != null && container.authService.callbackRouter.route(uri.toString())) return
        if (uri?.scheme == "meetingscheduler" && uri.host == "calendar" && uri.path == "/callback") {
            // Treat the link as a signal only; verify connection state with the API.
            lifecycleScope.launch { container.calendarService.refreshGoogleCalendarConnection() }
        }
    }
}
