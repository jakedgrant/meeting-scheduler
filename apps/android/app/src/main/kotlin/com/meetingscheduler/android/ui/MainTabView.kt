package com.meetingscheduler.android.ui

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.vector.ImageVector
import com.meetingscheduler.android.services.AuthService

sealed class Screen(val route: String, val title: String, val icon: ImageVector) {
    object Polls : Screen("polls", "Polls", Icons.Default.List)
    object Settings : Screen("settings", "Settings", Icons.Default.Settings)
}

@Composable
fun MainTabView(authService: AuthService) {
    var selectedScreen by remember { mutableStateOf<Screen>(Screen.Polls) }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    selected = selectedScreen == Screen.Polls,
                    onClick = { selectedScreen = Screen.Polls },
                    icon = { Icon(Screen.Polls.icon, contentDescription = Screen.Polls.title) },
                    label = { Text(Screen.Polls.title) }
                )
                NavigationBarItem(
                    selected = selectedScreen == Screen.Settings,
                    onClick = { selectedScreen = Screen.Settings },
                    icon = { Icon(Screen.Settings.icon, contentDescription = Screen.Settings.title) },
                    label = { Text(Screen.Settings.title) }
                )
            }
        }
    ) { paddingValues ->
        when (selectedScreen) {
            Screen.Polls -> PollListView(authService, paddingValues)
            Screen.Settings -> SettingsView(authService, paddingValues)
        }
    }
}
