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
import com.meetingscheduler.android.services.AccountScreenAuth

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
    authService: AccountScreenAuth,
    onDismiss: () -> Unit
) {
    // The holder is kept by the navigation entry's store, so the edits and a save in flight outlast the Activity.
    val holder = profileEditHolder(authService)
    val model = holder.opened.getOrThrow()
    var expandedTimezone by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Edit Profile") },
                navigationIcon = {
                    IconButton(onClick = onDismiss, enabled = !model.isSaving) {
                        Icon(Icons.Default.Close, "Cancel")
                    }
                },
                actions = {
                    TextButton(
                        onClick = { holder.launch { save() } },
                        enabled = !model.isSaving
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
                    value = model.displayName,
                    onValueChange = model::editDisplayName,
                    label = { Text("Display Name") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !model.isSaving
                )
            }

            item {
                OutlinedTextField(
                    value = model.avatarUrl,
                    onValueChange = model::editAvatarUrl,
                    label = { Text("Avatar URL") },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !model.isSaving
                )
            }

            // Avatar Preview
            if (model.avatarUrl.isNotBlank()) {
                item {
                    Box(
                        modifier = Modifier.fillMaxWidth(),
                        contentAlignment = Alignment.Center
                    ) {
                        AsyncImage(
                            model = model.avatarUrl,
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
                    onExpandedChange = { expandedTimezone = !expandedTimezone && !model.isSaving }
                ) {
                    OutlinedTextField(
                        value = model.timezone,
                        onValueChange = {},
                        readOnly = true,
                        label = { Text("Timezone") },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expandedTimezone) },
                        modifier = Modifier
                            .fillMaxWidth()
                            .menuAnchor(),
                        enabled = !model.isSaving
                    )

                    ExposedDropdownMenu(
                        expanded = expandedTimezone,
                        onDismissRequest = { expandedTimezone = false }
                    ) {
                        timezones.forEach { tz ->
                            DropdownMenuItem(
                                text = { Text(tz) },
                                onClick = {
                                    model.editTimezone(tz)
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
            model.errorMessage?.let { error ->
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
    if (model.saved) {
        AlertDialog(
            onDismissRequest = { },
            title = { Text("Profile Updated") },
            text = { Text("Your profile has been updated successfully") },
            confirmButton = {
                TextButton(onClick = {
                    model.acknowledgeSaved()
                    onDismiss()
                }) {
                    Text("OK")
                }
            }
        )
    }
}
