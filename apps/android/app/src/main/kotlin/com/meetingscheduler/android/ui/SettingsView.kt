package com.meetingscheduler.android.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.meetingscheduler.android.services.AccountScreenAuth
import com.meetingscheduler.android.services.ScreenBilling
import com.meetingscheduler.android.services.SettingsCalendar

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsView(
    authService: AccountScreenAuth,
    purchaseService: ScreenBilling<*>?,
    calendarService: SettingsCalendar,
    onNavigateToProfileEdit: () -> Unit,
    onNavigateToPaywall: () -> Unit
) {
    // The holder is kept by the navigation entry's store, so a sign-out or purchase check outlasts the Activity.
    val holder = settingsHolder(authService, purchaseService, calendarService)
    val model = holder.opened.getOrThrow()

    // Calendar permission launcher
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        holder.launch { deviceCalendarPermissionResult(isGranted) }
    }

    val displayName = model.displayName
    val initials = model.initials

    Scaffold(
        topBar = {
            TopAppBar(title = { Text("Settings") })
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Profile Section
            item {
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(onClick = onNavigateToProfileEdit)
                ) {
                    Row(
                        modifier = Modifier.padding(16.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        // Avatar
                        val avatarUrl = model.avatarUrl

                        if (!avatarUrl.isNullOrBlank()) {
                            AsyncImage(
                                model = avatarUrl,
                                contentDescription = "Avatar",
                                modifier = Modifier
                                    .size(50.dp)
                                    .clip(CircleShape),
                                contentScale = ContentScale.Crop
                            )
                        } else {
                            Box(
                                modifier = Modifier
                                    .size(50.dp)
                                    .background(
                                        MaterialTheme.colorScheme.primaryContainer,
                                        CircleShape
                                    ),
                                contentAlignment = Alignment.Center
                            ) {
                                Text(
                                    initials,
                                    style = MaterialTheme.typography.titleMedium,
                                    color = MaterialTheme.colorScheme.onPrimaryContainer
                                )
                            }
                        }

                        // User Info
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                displayName,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold
                            )
                            Text(
                                model.email,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }

                        Icon(
                            Icons.Default.ChevronRight,
                            null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Subscription Section
            item {
                Text("Subscription", style = MaterialTheme.typography.titleMedium)
            }

            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column {
                        if (model.hasProAccess) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(Icons.Default.Star, null, tint = Color(0xFFFFD700))
                                    Text("Pro")
                                }
                                Text("Active", color = Color.Green)
                            }
                        } else {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(onClick = onNavigateToPaywall)
                                    .padding(16.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(Icons.Default.Star, null)
                                    Text("Upgrade to Pro")
                                }
                                Icon(
                                    Icons.Default.ChevronRight,
                                    null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        Divider()

                        TextButton(
                            onClick = { holder.launch { restorePurchases() } },
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp)
                        ) {
                            Text("Restore Purchases")
                        }
                    }
                }
            }

            // Calendar Integration Section
            item {
                Text("Calendar Integration", style = MaterialTheme.typography.titleMedium)
            }

            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Text(
                            "Select calendar sources to check for conflicts",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )

                        // Apple (Android) Calendar Toggle
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    Icons.Default.CalendarToday,
                                    null,
                                    tint = MaterialTheme.colorScheme.primary
                                )
                                Column {
                                    Text("Android Calendar", style = MaterialTheme.typography.bodyMedium)
                                    Text(
                                        "Local device calendar",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant
                                    )
                                }
                            }

                            Switch(
                                checked = calendarService.appleCalendarEnabled,
                                onCheckedChange = { enabled ->
                                    holder.launch {
                                        toggleDeviceCalendar(enabled) {
                                            permissionLauncher.launch(Manifest.permission.READ_CALENDAR)
                                        }
                                    }
                                }
                            )
                        }

                        Divider()

                        // Google Calendar Toggle
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    Icons.Default.Language,
                                    null,
                                    tint = Color.Red
                                )
                                Column {
                                    Text("Google Calendar", style = MaterialTheme.typography.bodyMedium)
                                    if (calendarService.googleCalendarEnabled) {
                                        Text(
                                            calendarService.googleCalendarAccountEmail ?: "Connected",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = Color.Green
                                        )
                                    } else {
                                        Text(
                                            "Not connected",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant
                                        )
                                    }
                                }
                            }

                            Switch(
                                checked = calendarService.googleCalendarEnabled,
                                onCheckedChange = { enabled -> holder.launch { setGoogleCalendar(enabled) } },
                                enabled = !calendarService.googleCalendarLoading
                            )
                        }

                        calendarService.calendarError?.let { message ->
                            Text(message, style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }

                        if (calendarService.googleCalendarLoading) {
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp))
                                Text(
                                    "Checking Google Calendar connection...",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    }
                }
            }

            // App Section
            item {
                Text("App", style = MaterialTheme.typography.titleMedium)
            }

            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text("Version")
                        Text(
                            "1.0.0",
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // Sign Out Section
            item {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer
                    ),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Button(
                        onClick = { holder.launch { signOut() } },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error
                        ),
                        enabled = !model.isSigningOut
                    ) {
                        if (model.isSigningOut) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                color = MaterialTheme.colorScheme.onError
                            )
                        } else {
                            Text("Sign Out")
                        }
                    }
                }
            }
        }
    }
}
