package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.key
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService

@Composable
fun ContentView(
    authService: AuthService,
    pollService: PollService,
    calendarService: CalendarService,
    purchaseService: PurchaseService?,
    screens: PollScreenEnvironment,
) {
    // Kept across Activity recreation; hands each session its own ViewModelStore (F13, F12).
    val sessionStores = viewModel<SessionViewModelStores>(
        factory = SessionViewModelStores.Factory { authService.identityGeneration },
    )
    when {
        authService.isLoading -> LoadingView()
        authService.isAuthenticated -> SessionScope(sessionStores, authService.identityGeneration) {
            MainTabView(
                authService = authService,
                pollService = pollService,
                calendarService = calendarService,
                purchaseService = purchaseService,
                screens = screens,
            )
        }
        // The signed-out screen gets the store of the current generation too, so signing in or out ends its model.
        else -> SessionScope(sessionStores, authService.identityGeneration) { AuthView(authService) }
    }
}

/**
 * Composes [content] in the session store for [generation]. Each NavHost inside it calls
 * `navController.setViewModelStore` with this `LocalViewModelStoreOwner`, which nests every
 * navigation entry's store here (F12, F13). A new generation recomposes from a new key, and the
 * session store has already cleared the older generation's stores.
 */
@Composable
fun SessionScope(sessionStores: SessionViewModelStores, generation: Long, content: @Composable () -> Unit) {
    key(generation) {
        CompositionLocalProvider(
            LocalViewModelStoreOwner provides sessionStores.storeOwnerFor(generation),
            content = content,
        )
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
