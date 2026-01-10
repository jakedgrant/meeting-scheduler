package com.meetingscheduler.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.lifecycle.lifecycleScope
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.PurchaseService
import com.meetingscheduler.android.ui.ContentView
import com.meetingscheduler.android.ui.theme.MeetingSchedulerTheme

class MainActivity : ComponentActivity() {
    private lateinit var authService: AuthService
    private lateinit var purchaseService: PurchaseService

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Initialize services
        authService = AuthService.getInstance(this, lifecycleScope)
        purchaseService = PurchaseService.getInstance(application, lifecycleScope)

        setContent {
            MeetingSchedulerTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ContentView(authService = authService)
                }
            }
        }
    }
}
