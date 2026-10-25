package com.meetingscheduler.android.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.meetingscheduler.android.services.AuthService
import kotlinx.coroutines.launch

val timezones = listOf(
    "UTC",
    "America/New_York",
    "America/Chicago",
    "America/Denver",
    "America/Los_Angeles",
    "America/Phoenix",
    "America/Anchorage",
    "Pacific/Honolulu",
    "Europe/London",
    "Europe/Paris",
    "Europe/Berlin",
    "Europe/Rome",
    "Europe/Madrid",
    "Asia/Dubai",
    "Asia/Kolkata",
    "Asia/Singapore",
    "Asia/Tokyo",
    "Asia/Hong_Kong",
    "Asia/Shanghai",
    "Australia/Sydney",
    "Australia/Melbourne",
    "Pacific/Auckland"
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProfileEditView(
    authService: AuthService,
    onDismiss: () -> Unit
) {
    var displayName by remember { mutableStateOf(authService.profile?.displayName ?: "") }
    var avatarUrl by remember { mutableStateOf(authService.profile?.avatarUrl ?: "") }
    var timezone by remember { mutableStateOf(authService.profile?.timezone ?: "UTC") }
    var isSaving by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var showSuccessDialog by remember { mutableStateOf(false) }
    var expandedTimezone by remember { mutableStateOf(false) }

    val scope = rememberCoroutineScope()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Edit Profile") },
                navigationIcon = {
                    IconButton(onClick = onDismiss, enabled = !isSaving) {
                        Icon(Icons.Default.Close, "Cancel")
                    }
                },
                actions = {
                    TextButton(
                        onClick = {
                            scope.launch {
                                val owner = authService.currentUser?.id
                                val generation = authService.identityGeneration
                                isSaving = true
                                errorMessage = null
                                try {
                                    authService.updateProfile(
                                        displayName = displayName.ifBlank { null },
                                        avatarUrl = avatarUrl.ifBlank { null },
                                        timezone = timezone
                                    )
                                    if (authService.isCurrent(owner, generation)) showSuccessDialog = true
                                } catch (e: kotlinx.coroutines.CancellationException) { throw e
                                } catch (e: Exception) {
                                    if (authService.isCurrent(owner, generation)) errorMessage = "Failed to update profile: ${e.message}"
                                } finally {
                                    if (authService.isCurrent(owner, generation)) isSaving = false
                                }
                            }
                        },
                        enabled = !isSaving
                    ) {
                        Text("Save")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            item {
                Text("Profile Information", style = MaterialTheme.typography.titleMedium)
            }

            item {
                OutlinedTextField(
                    value = displayName,
                    onValueChange = { displayName = it },
                    label = { Text("Display Name") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isSaving
                )
            }

            item {
                OutlinedTextField(
                    value = avatarUrl,
                    onValueChange = { avatarUrl = it },
                    label = { Text("Avatar URL") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isSaving
                )
            }

            // Avatar Preview
            if (avatarUrl.isNotBlank()) {
                item {
                    Box(
                        modifier = Modifier.fillMaxWidth(),
                        contentAlignment = Alignment.Center
                    ) {
                        AsyncImage(
                            model = avatarUrl,
                            contentDescription = "Avatar preview",
                            modifier = Modifier
                                .size(100.dp)
                                .clip(CircleShape),
                            contentScale = ContentScale.Crop
                        )
                    }
                }
            }

            item {
                Text(
                    "Your display name and avatar will be shown to other participants",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            item {
                Spacer(Modifier.height(8.dp))
                Text("Timezone", style = MaterialTheme.typography.titleMedium)
            }

            item {
                ExposedDropdownMenuBox(
                    expanded = expandedTimezone,
                    onExpandedChange = { expandedTimezone = !expandedTimezone && !isSaving }
                ) {
                    OutlinedTextField(
                        value = timezone,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Timezone") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expandedTimezone) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .menuAnchor(),
                        enabled = !isSaving
                    )

                    ExposedDropdownMenu(
                        expanded = expandedTimezone,
                        onDismissRequest = { expandedTimezone = false }
                    ) {
                        timezones.forEach { tz ->
                            DropdownMenuItem(
                                text = { Text(tz) },
                                onClick = {
                                    timezone = tz
                                    expandedTimezone = false
                                }
                            )
                        }
                    }
                }
            }

            item {
                Text(
                    "Your local timezone for meeting scheduling",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Error Message
            errorMessage?.let { error ->
                item {
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer
                        )
                    ) {
                        Text(
                            text = error,
                            color = MaterialTheme.colorScheme.onErrorContainer,
                            modifier = Modifier.padding(16.dp)
                        )
                    }
                }
            }
        }
    }

    // Success Dialog
    if (showSuccessDialog) {
        AlertDialog(
            onDismissRequest = { },
            title = { Text("Profile Updated") },
            text = { Text("Your profile has been updated successfully") },
            confirmButton = {
                TextButton(onClick = {
                    showSuccessDialog = false
                    onDismiss()
                }) {
                    Text("OK")
                }
            }
        )
    }
}
