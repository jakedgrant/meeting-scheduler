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
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PurchaseService
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsView(
    authService: AuthService,
    purchaseService: PurchaseService?,
    calendarService: CalendarService,
    onNavigateToProfileEdit: () -> Unit,
    onNavigateToPaywall: () -> Unit
) {
    var isSigningOut by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // Calendar permission launcher
    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            scope.launch {
                calendarService.setAppleCalendarEnabled(true)
            }
        }
    }

    val displayName = authService.profile?.displayName
        ?: authService.currentUser?.email
        ?: "User"

    val initials = remember(displayName) {
        val components = displayName.split(" ")
        if (components.size >= 2) {
            (components[0].firstOrNull()?.toString() ?: "") +
                    (components[1].firstOrNull()?.toString() ?: "")
        } else {
            displayName.take(2)
        }.uppercase()
    }

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
                        val avatarUrl = authService.profile?.avatarUrl

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
                                authService.currentUser?.email ?: "",
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
                        if (purchaseService?.hasProAccess == true) {
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
                            onClick = {
                                scope.launch {
                                    try {
                                        purchaseService?.restorePurchases()
                                    } catch (e: Exception) {
                                        println("Restore failed: ${e.message}")
                                    }
                                }
                            },
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
                                    if (enabled) {
                                        if (!calendarService.hasCalendarPermission) {
                                            permissionLauncher.launch(Manifest.permission.READ_CALENDAR)
                                        } else {
                                            scope.launch {
                                                calendarService.setAppleCalendarEnabled(true)
                                            }
                                        }
                                    } else {
                                        scope.launch {
                                            calendarService.setAppleCalendarEnabled(false)
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
                                onCheckedChange = { enabled ->
                                    scope.launch {
                                        calendarService.setGoogleCalendarEnabled(enabled)
                                    }
                                },
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
                        onClick = {
                            scope.launch {
                                isSigningOut = true
                                try {
                                    authService.signOut()
                                } catch (e: Exception) {
                                    println("Sign out failed: ${e.message}")
                                }
                                isSigningOut = false
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.error
                        ),
                        enabled = !isSigningOut
                    ) {
                        if (isSigningOut) {
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
