package com.meetingscheduler.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.models.PollCreationEntitlement
import com.meetingscheduler.android.services.AccountScreenAuth
import com.meetingscheduler.android.services.ScreenBilling
import com.revenuecat.purchases.Package

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallView(
    authService: AccountScreenAuth,
    purchaseService: ScreenBilling<Package>?,
    onDismiss: () -> Unit
) {
    // The holder is kept by the navigation entry's store, so a purchase in flight outlasts the Activity.
    val holder = paywallHolder(authService, purchaseService)
    val model = holder.opened.getOrThrow()
    LaunchedEffect(model.finished) { if (model.finished) onDismiss() }

    val activity = LocalContext.current as? android.app.Activity

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("") },
                navigationIcon = {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.Default.Close, "Close")
                    }
                }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(24.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // Header
            item {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        Icons.Default.Star,
                        null,
                        modifier = Modifier.size(50.dp),
                        tint = Color(0xFFFFD700)
                    )

                    Text(
                        "Upgrade to Pro",
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold
                    )

                    Text(
                        "Unlock unlimited polls and premium features",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center
                    )
                }
            }

            // Packages Section
            if (model.isLoading) {
                item {
                    CircularProgressIndicator()
                }
            } else if (model.packages.isEmpty()) {
                item {
                    Text(
                        "No plans available",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                items(model.packages) { pkg ->
                    PackageCard(
                        package_ = pkg,
                        isSelected = model.selected?.identifier == pkg.identifier,
                        onClick = { model.select(pkg) }
                    )
                }
            }

            // Features Section
            item {
                Card(
                    colors = CardDefaults.cardColors(
                        containerColor = MaterialTheme.colorScheme.surfaceVariant
                    )
                ) {
                    Column(
                        modifier = Modifier.padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        Text("What you get:", style = MaterialTheme.typography.titleSmall)

                        if (PollCreationEntitlement.PRO.allowsUnlimitedActivePolls) {
                            FeatureRow(Icons.Default.AllInclusive, "Unlimited active polls")
                        }
                        FeatureRow(Icons.Default.People, "Up to ${PollCreationEntitlement.PRO.participantLimit} participants per poll")
                        FeatureRow(Icons.Default.CalendarToday, "Calendar integrations")
                        FeatureRow(Icons.Default.Notifications, "Priority notifications")
                    }
                }
            }

            // Error Message
            model.errorMessage?.let { error ->
                item {
                    Text(
                        error,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall
                    )
                }
            }

            // Purchase Button
            item {
                Button(
                    onClick = { holder.launch { purchase(activity) } },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp),
                    enabled = model.selected != null && !model.isPurchasing,
                    shape = RoundedCornerShape(12.dp)
                ) {
                    if (model.isPurchasing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                    } else {
                        Text("Subscribe Now")
                    }
                }
            }

            // Restore Button
            item {
                TextButton(onClick = { holder.launch { restore() } }) {
                    Text("Restore Purchases")
                }
            }

            // Terms Text
            item {
                Text(
                    "Cancel anytime. By subscribing, you agree to our Terms of Service.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                    textAlign = TextAlign.Center
                )
            }
        }
    }
}

@Composable
fun PackageCard(
    package_: Package,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    val packageTitle = when {
        package_.identifier.lowercase().contains("team") -> "Team"
        package_.identifier.lowercase().contains("pro") -> "Pro"
        else -> package_.identifier
    }

    val packagePeriod = when (package_.packageType) {
        com.revenuecat.purchases.PackageType.ANNUAL -> "Yearly"
        com.revenuecat.purchases.PackageType.MONTHLY -> "Monthly"
        else -> ""
    }

    val isAnnual = package_.packageType == com.revenuecat.purchases.PackageType.ANNUAL

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .then(
                if (isSelected) {
                    Modifier.border(
                        width = 2.dp,
                        color = MaterialTheme.colorScheme.primary,
                        shape = RoundedCornerShape(12.dp)
                    )
                } else {
                    Modifier
                }
            ),
        colors = CardDefaults.cardColors(
            containerColor = if (isSelected) {
                MaterialTheme.colorScheme.primaryContainer
            } else {
                MaterialTheme.colorScheme.surfaceVariant
            }
        )
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(packageTitle, style = MaterialTheme.typography.titleMedium)
                Text(
                    packagePeriod,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Column(
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    package_.product.price.formatted,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary
                )

                if (isAnnual) {
                    Text(
                        "Save 17%",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Green
                    )
                }
            }
        }
    }
}

@Composable
fun FeatureRow(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            icon,
            null,
            modifier = Modifier.size(24.dp),
            tint = MaterialTheme.colorScheme.primary
        )
        Text(text, style = MaterialTheme.typography.bodyMedium)
    }
}
