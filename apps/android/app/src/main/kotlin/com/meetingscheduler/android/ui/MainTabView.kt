package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainTabView(
    authService: AuthService,
    pollService: PollService,
    calendarService: CalendarService,
    purchaseService: PurchaseService?
) {
    var selectedTab by remember { mutableStateOf(0) }

    Scaffold(
        bottomBar = {
            NavigationBar {
                NavigationBarItem(
                    icon = { Icon(Icons.Default.List, "Polls") },
                    label = { Text("Polls") },
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 }
                )
                NavigationBarItem(
                    icon = { Icon(Icons.Default.Settings, "Settings") },
                    label = { Text("Settings") },
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 }
                )
            }
        }
    ) { padding ->
        Box(modifier = Modifier.padding(padding)) {
            when (selectedTab) {
                0 -> {
                    // Polls Tab with Navigation
                    val pollNavController = rememberNavController()
                    PollNavHost(
                        navController = pollNavController,
                        authService = authService,
                        pollService = pollService,
                        calendarService = calendarService,
                        purchaseService = purchaseService
                    )
                }
                1 -> {
                    // Settings Tab with Navigation
                    val settingsNavController = rememberNavController()
                    NavHost(
                        navController = settingsNavController,
                        startDestination = "settings"
                    ) {
                        composable("settings") {
                            SettingsView(
                                authService = authService,
                                purchaseService = purchaseService,
                                calendarService = calendarService,
                                onNavigateToProfileEdit = {
                                    settingsNavController.navigate("profile_edit")
                                },
                                onNavigateToPaywall = {
                                    settingsNavController.navigate("paywall")
                                }
                            )
                        }

                        composable("profile_edit") {
                            ProfileEditView(
                                authService = authService,
                                onDismiss = { settingsNavController.popBackStack() }
                            )
                        }

                        composable("paywall") {
                            PaywallView(
                                purchaseService = purchaseService,
                                onDismiss = { settingsNavController.popBackStack() }
                            )
                        }
                    }
                }
            }
        }
    }
}
