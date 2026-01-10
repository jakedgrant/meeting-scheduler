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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.meetingscheduler.android.services.PurchaseService
import com.revenuecat.purchases.Package
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaywallView(
    purchaseService: PurchaseService?,
    onDismiss: () -> Unit
) {
    var selectedPackage by remember { mutableStateOf<Package?>(null) }
    var isPurchasing by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var isLoading by remember { mutableStateOf(true) }
    var availablePackages by remember { mutableStateOf<List<Package>>(emptyList()) }

    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        purchaseService?.let {
            it.loadOfferings()
            availablePackages = it.currentOffering?.availablePackages ?: emptyList()
        }
        isLoading = false
    }

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
            if (isLoading) {
                item {
                    CircularProgressIndicator()
                }
            } else if (availablePackages.isEmpty()) {
                item {
                    Text(
                        "No plans available",
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            } else {
                items(availablePackages) { pkg ->
                    PackageCard(
                        package_ = pkg,
                        isSelected = selectedPackage?.identifier == pkg.identifier,
                        onClick = { selectedPackage = pkg }
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

                        FeatureRow(Icons.Default.Infinity, "Unlimited active polls")
                        FeatureRow(Icons.Default.People, "Up to 50 participants per poll")
                        FeatureRow(Icons.Default.CalendarToday, "Calendar integrations")
                        FeatureRow(Icons.Default.Notifications, "Priority notifications")
                    }
                }
            }

            // Error Message
            errorMessage?.let { error ->
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
                    onClick = {
                        selectedPackage?.let { pkg ->
                            scope.launch {
                                isPurchasing = true
                                errorMessage = null
                                try {
                                    purchaseService?.purchase(pkg)
                                    onDismiss()
                                } catch (e: Exception) {
                                    errorMessage = e.message
                                }
                                isPurchasing = false
                            }
                        }
                    },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp),
                    enabled = selectedPackage != null && !isPurchasing,
                    shape = RoundedCornerShape(12.dp)
                ) {
                    if (isPurchasing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            color = MaterialTheme.colorScheme.onPrimary
                        )
                    } else {
                        Text(if (isPurchasing) "Processing..." else "Subscribe Now")
                    }
                }
            }

            // Restore Button
            item {
                TextButton(onClick = {
                    scope.launch {
                        isPurchasing = true
                        errorMessage = null
                        try {
                            purchaseService?.let {
                                it.restorePurchases()
                                if (it.hasProAccess) {
                                    onDismiss()
                                } else {
                                    errorMessage = "No purchases to restore"
                                }
                            }
                        } catch (e: Exception) {
                            errorMessage = e.message
                        }
                        isPurchasing = false
                    }
                }) {
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
