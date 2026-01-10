package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService

@Composable
fun ContentView(
    authService: AuthService,
    pollService: PollService,
    calendarService: CalendarService,
    purchaseService: PurchaseService?
) {
    when {
        authService.isLoading -> LoadingView()
        authService.isAuthenticated -> MainTabView(
            authService = authService,
            pollService = pollService,
            calendarService = calendarService,
            purchaseService = purchaseService
        )
        else -> AuthView(authService)
    }
}

@Composable
fun LoadingView() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        CircularProgressIndicator()
        Text("Loading...")
    }
}
