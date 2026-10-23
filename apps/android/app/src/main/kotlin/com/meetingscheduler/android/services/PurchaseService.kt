package com.meetingscheduler.android.services

import android.app.Activity
import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.BuildConfig
import com.meetingscheduler.android.Config
import com.revenuecat.purchases.CustomerInfo
import com.revenuecat.purchases.LogLevel
import com.revenuecat.purchases.Offerings
import com.revenuecat.purchases.Package
import com.revenuecat.purchases.PurchaseParams
import com.revenuecat.purchases.Purchases
import com.revenuecat.purchases.PurchasesConfiguration
import com.revenuecat.purchases.awaitCustomerInfo
import com.revenuecat.purchases.awaitLogIn
import com.revenuecat.purchases.awaitLogOut
import com.revenuecat.purchases.awaitOfferings
import com.revenuecat.purchases.awaitPurchase
import com.revenuecat.purchases.awaitRestore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/** Process-lifetime billing state (F13), created by [com.meetingscheduler.android.AppContainer]. */
class PurchaseService(
    private val application: Application,
    private val scope: CoroutineScope
) : BillingIdentity {
    var customerInfo by mutableStateOf<CustomerInfo?>(null)
        private set
    var offerings by mutableStateOf<Offerings?>(null)
        private set
    var isLoading by mutableStateOf(false)
        private set

    val hasProAccess: Boolean
        get() = customerInfo?.entitlements?.get("pro_access")?.isActive == true ||
                customerInfo?.entitlements?.get("team_access")?.isActive == true

    val hasTeamAccess: Boolean
        get() = customerInfo?.entitlements?.get("team_access")?.isActive == true

    val currentOffering: com.revenuecat.purchases.Offering?
        get() = offerings?.current

    init {
        configure()
    }

    private fun configure() {
        // Verbose billing diagnostics only in debug builds (F26/F27).
        Purchases.logLevel = if (BuildConfig.DEBUG) LogLevel.DEBUG else LogLevel.WARN

        val configuration = PurchasesConfiguration.Builder(
            context = application,
            apiKey = Config.REVENUE_CAT_API_KEY
        ).build()

        Purchases.configure(configuration)

        // Get initial customer info
        scope.launch {
            refreshCustomerInfo()
            loadOfferings()
        }
    }

    // MARK: - User Management

    override suspend fun login(userId: String) {
        try {
            val result = Purchases.sharedInstance.awaitLogIn(userId)
            customerInfo = result.customerInfo
            println("RevenueCat logged in: ${result.customerInfo.originalAppUserId}")
        } catch (e: Exception) {
            println("RevenueCat login failed: ${e.message}")
        }
    }

    override suspend fun logout() {
        try {
            val info = Purchases.sharedInstance.awaitLogOut()
            customerInfo = info
        } catch (e: Exception) {
            println("RevenueCat logout failed: ${e.message}")
        }
    }

    // MARK: - Customer Info

    suspend fun refreshCustomerInfo() {
        try {
            customerInfo = Purchases.sharedInstance.awaitCustomerInfo()
        } catch (e: Exception) {
            println("Failed to get customer info: ${e.message}")
        }
    }

    // MARK: - Offerings

    suspend fun loadOfferings() {
        isLoading = true
        try {
            offerings = Purchases.sharedInstance.awaitOfferings()
        } catch (e: Exception) {
            println("Failed to load offerings: ${e.message}")
        } finally {
            isLoading = false
        }
    }

    // MARK: - Purchases

    suspend fun purchase(activity: Activity, packageToPurchase: Package): CustomerInfo {
        val purchaseParams = PurchaseParams.Builder(activity, packageToPurchase).build()
        val result = Purchases.sharedInstance.awaitPurchase(purchaseParams)
        customerInfo = result.customerInfo
        return result.customerInfo
    }

    suspend fun restorePurchases(): CustomerInfo {
        val info = Purchases.sharedInstance.awaitRestore()
        customerInfo = info
        return info
    }
}
