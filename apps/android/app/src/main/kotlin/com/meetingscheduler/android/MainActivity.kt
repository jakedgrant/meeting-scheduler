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
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService
import com.meetingscheduler.android.ui.ContentView
import com.meetingscheduler.android.ui.theme.MeetingSchedulerTheme

class MainActivity : ComponentActivity() {
    private lateinit var authService: AuthService
    private lateinit var pollService: PollService
    private lateinit var calendarService: CalendarService
    private var purchaseService: PurchaseService? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Initialize services
        authService = AuthService.getInstance(this, lifecycleScope)
        pollService = PollService.getInstance(authService, lifecycleScope)
        calendarService = CalendarService.getInstance(this, authService, lifecycleScope)
        try {
            purchaseService = PurchaseService.getInstance(application, lifecycleScope)
        } catch (e: Exception) {
            println("Failed to initialize PurchaseService: ${e.message}")
        }

        setContent {
            MeetingSchedulerTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ContentView(
                        authService = authService,
                        pollService = pollService,
                        calendarService = calendarService,
                        purchaseService = purchaseService
                    )
                }
            }
        }
    }
    override fun onResume() {
        super.onResume()
        if (::calendarService.isInitialized) {
            lifecycleScope.launch { calendarService.refreshGoogleCalendarConnection() }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = intent.data
        if (uri?.scheme == "meetingscheduler" && uri.host == "calendar" && uri.path == "/callback") {
            // Treat the link as a signal only; verify connection state with the API.
            lifecycleScope.launch { calendarService.refreshGoogleCalendarConnection() }
        }
    }

}
