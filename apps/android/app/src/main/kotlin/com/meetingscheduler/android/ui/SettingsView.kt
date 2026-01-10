package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PurchaseService
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsView(authService: AuthService, paddingValues: PaddingValues) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val calendarService = remember {
        CalendarService.getInstance(context, authService, scope)
    }
    val purchaseService = remember { PurchaseService.instance }
    var showProfileEdit by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Settings") })
        },
        modifier = Modifier.padding(paddingValues)
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
        ) {
            // Profile Section
            ListItem(
                headlineContent = { Text("Profile") },
                supportingContent = {
                    Text(authService.profile?.displayName ?: authService.profile?.email ?: "")
                },
                leadingContent = {
                    Icon(Icons.Default.Person, contentDescription = null)
                },
                modifier = Modifier.clickable { showProfileEdit = true }
            )

            Divider()

            // Subscription Section
            ListItem(
                headlineContent = { Text("Subscription") },
                supportingContent = {
                    Text(
                        if (purchaseService?.hasProAccess == true) "Pro"
                        else if (purchaseService?.hasTeamAccess == true) "Team"
                        else "Free"
                    )
                }
            )

            Divider()

            // Calendar Integration Section
            Text(
                "Calendar Integration",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(16.dp)
            )

            ListItem(
                headlineContent = { Text("Calendar Access") },
                supportingContent = { Text("Detect scheduling conflicts") },
                trailingContent = {
                    Switch(
                        checked = calendarService.appleCalendarEnabled,
                        onCheckedChange = { enabled ->
                            scope.launch {
                                calendarService.setAppleCalendarEnabled(enabled)
                            }
                        }
                    )
                }
            )

            ListItem(
                headlineContent = { Text("Google Calendar") },
                supportingContent = { Text("Check Google Calendar for conflicts") },
                trailingContent = {
                    Switch(
                        checked = calendarService.googleCalendarEnabled,
                        onCheckedChange = { enabled ->
                            scope.launch {
                                calendarService.setGoogleCalendarEnabled(enabled)
                            }
                        }
                    )
                }
            )

            Divider()

            // Sign Out
            ListItem(
                headlineContent = { Text("Sign Out") },
                modifier = Modifier.clickable {
                    scope.launch {
                        authService.signOut()
                    }
                }
            )
        }
    }

    if (showProfileEdit) {
        ProfileEditDialog(
            authService = authService,
            onDismiss = { showProfileEdit = false }
        )
    }
}

@Composable
fun ProfileEditDialog(authService: AuthService, onDismiss: () -> Unit) {
    var displayName by remember { mutableStateOf(authService.profile?.displayName ?: "") }
    var avatarUrl by remember { mutableStateOf(authService.profile?.avatarUrl ?: "") }
    var timezone by remember { mutableStateOf(authService.profile?.timezone ?: "UTC") }
    val scope = rememberCoroutineScope()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Edit Profile") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = displayName,
                    onValueChange = { displayName = it },
                    label = { Text("Display Name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = avatarUrl,
                    onValueChange = { avatarUrl = it },
                    label = { Text("Avatar URL") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                OutlinedTextField(
                    value = timezone,
                    onValueChange = { timezone = it },
                    label = { Text("Timezone") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    scope.launch {
                        try {
                            authService.updateProfile(
                                displayName = displayName.ifBlank { null },
                                avatarUrl = avatarUrl.ifBlank { null },
                                timezone = timezone.ifBlank { null }
                            )
                            onDismiss()
                        } catch (e: Exception) {
                            // Handle error
                        }
                    }
                }
            ) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
