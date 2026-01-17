package com.meetingscheduler.android.ui

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navArgument
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService

sealed class Screen(val route: String) {
    object PollList : Screen("poll_list")
    object CreatePoll : Screen("create_poll")
    object PollDetail : Screen("poll_detail/{pollId}") {
        fun createRoute(pollId: String) = "poll_detail/$pollId"
    }
    object TimeOptionResponses : Screen("time_option_responses/{pollId}/{timeOptionId}") {
        fun createRoute(pollId: String, timeOptionId: String) = "time_option_responses/$pollId/$timeOptionId"
    }
    object Settings : Screen("settings")
    object ProfileEdit : Screen("profile_edit")
    object Paywall : Screen("paywall")
}

@Composable
fun PollNavHost(
    navController: NavHostController,
    authService: AuthService,
    pollService: PollService,
    calendarService: CalendarService,
    purchaseService: PurchaseService?
) {
    NavHost(navController = navController, startDestination = Screen.PollList.route) {
        composable(Screen.PollList.route) {
            PollListView(
                pollService = pollService,
                purchaseService = purchaseService,
                onNavigateToPoll = { pollId ->
                    navController.navigate(Screen.PollDetail.createRoute(pollId))
                },
                onNavigateToCreatePoll = {
                    navController.navigate(Screen.CreatePoll.route)
                },
                onNavigateToPaywall = {
                    navController.navigate(Screen.Paywall.route)
                }
            )
        }

        composable(Screen.CreatePoll.route) {
            CreatePollView(
                pollService = pollService,
                onDismiss = { navController.popBackStack() }
            )
        }

        composable(
            route = Screen.PollDetail.route,
            arguments = listOf(navArgument("pollId") { type = NavType.StringType })
        ) { backStackEntry ->
            val pollId = backStackEntry.arguments?.getString("pollId") ?: return@composable
            PollDetailView(
                pollId = pollId,
                authService = authService,
                pollService = pollService,
                calendarService = calendarService,
                onNavigateToResponses = { timeOptionId ->
                    navController.navigate(Screen.TimeOptionResponses.createRoute(pollId, timeOptionId))
                },
                onNavigateBack = { navController.popBackStack() }
            )
        }

        composable(
            route = Screen.TimeOptionResponses.route,
            arguments = listOf(
                navArgument("pollId") { type = NavType.StringType },
                navArgument("timeOptionId") { type = NavType.StringType }
            )
        ) { backStackEntry ->
            val pollId = backStackEntry.arguments?.getString("pollId") ?: return@composable
            val timeOptionId = backStackEntry.arguments?.getString("timeOptionId") ?: return@composable
            TimeOptionResponsesView(
                pollId = pollId,
                timeOptionId = timeOptionId,
                pollService = pollService,
                onNavigateBack = { navController.popBackStack() }
            )
        }

        composable(Screen.Settings.route) {
            SettingsView(
                authService = authService,
                purchaseService = purchaseService,
                calendarService = calendarService,
                onNavigateToProfileEdit = {
                    navController.navigate(Screen.ProfileEdit.route)
                },
                onNavigateToPaywall = {
                    navController.navigate(Screen.Paywall.route)
                }
            )
        }

        composable(Screen.ProfileEdit.route) {
            ProfileEditView(
                authService = authService,
                onDismiss = { navController.popBackStack() }
            )
        }

        composable(Screen.Paywall.route) {
            PaywallView(
                purchaseService = purchaseService,
                onDismiss = { navController.popBackStack() }
            )
        }
    }
}
