package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.meetingscheduler.android.services.AuthService

@Composable
fun ContentView(authService: AuthService) {
    when {
        authService.isLoading -> LoadingView()
        authService.isAuthenticated -> MainTabView(authService)
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
