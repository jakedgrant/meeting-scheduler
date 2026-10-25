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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Process-lifetime billing state (F13), created by [com.meetingscheduler.android.AppContainer]. */
class PurchaseService(
    private val application: Application?,
    private val scope: CoroutineScope,
    private val provider: BillingProvider = RevenueCatBillingProvider(),
) : BillingIdentity {
    private val providerLock = Mutex()
    private var accountId: String? = null
    private var generation = 0L
    private var identityReady = kotlinx.coroutines.CompletableDeferred<Boolean>()
    private var offeringRevision = 0L
    private var reconciledId: String? = null
    override fun resetIdentity(userId: String?, generation: Long) {
        identityReady.complete(false)
        identityReady = kotlinx.coroutines.CompletableDeferred()
        accountId = userId
        this.generation = generation
        customerInfo = null
        offeringRevision++
        offerings = null
        isLoading = false
    }
    private fun current(id: String?, stamp: Long) = accountId == id && generation == stamp

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
        if (application != null) configure()
    }

    private fun configure() {
        // Verbose billing diagnostics only in debug builds (F26/F27).
        Purchases.logLevel = if (BuildConfig.DEBUG) LogLevel.DEBUG else LogLevel.WARN

        val configuration = PurchasesConfiguration.Builder(
            context = requireNotNull(application),
            apiKey = Config.REVENUE_CAT_API_KEY
        ).build()

        Purchases.configure(configuration)

        // Personalized offerings load when the signed-in paywall requests them.
    }

    // MARK: - User Management

    override suspend fun login(userId: String) = providerLock.withLock {
        val stamp = generation
        val result = provider.login(userId)
        reconciledId = userId
        if (current(userId, stamp)) {
            customerInfo = result
            identityReady.complete(true)
        }
    }

    override suspend fun logout() = providerLock.withLock {
        val stamp = generation
        provider.logout()
        reconciledId = null
        if (current(null, stamp)) customerInfo = null
    }

    suspend fun refreshCustomerInfo() = providerLock.withLock {
        val id = accountId ?: return@withLock
        val stamp = generation
        if (reconciledId != id) return@withLock
        val info = provider.customerInfo()
        if (current(id, stamp)) customerInfo = info
    }

    // MARK: - Offerings

    suspend fun loadOfferings() {
        val id = accountId ?: return
        val stamp = generation
        val readiness = identityReady
        val revision = ++offeringRevision
        isLoading = true
        try {
            if (!readiness.await()) return
            providerLock.withLock {
                if (!current(id, stamp) || revision != offeringRevision || reconciledId != id) return@withLock
                val value = provider.offerings()
                if (current(id, stamp) && revision == offeringRevision) offerings = value
            }
        } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
        catch (_: Exception) {
            if (current(id, stamp) && revision == offeringRevision) offerings = null
        } finally {
            if (current(id, stamp) && revision == offeringRevision) isLoading = false
        }
    }

    // MARK: - Purchases

    suspend fun purchase(activity: Activity, packageToPurchase: Package): CustomerInfo = providerLock.withLock {
        val id = checkNotNull(accountId) { "Sign in before purchasing." }
        val stamp = generation
        check(reconciledId == id) { "Your billing account is being updated. Try again." }
        val purchaseParams = PurchaseParams.Builder(activity, packageToPurchase).build()
        val result = provider.purchase(purchaseParams)
        if (!current(id, stamp)) throw kotlinx.coroutines.CancellationException("Account changed")
        customerInfo = result
        result
    }

    suspend fun restorePurchases(): CustomerInfo = providerLock.withLock {
        val id = checkNotNull(accountId) { "Sign in before restoring purchases." }
        val stamp = generation
        check(reconciledId == id) { "Your billing account is being updated. Try again." }
        val info = provider.restore()
        if (!current(id, stamp)) throw kotlinx.coroutines.CancellationException("Account changed")
        customerInfo = info
        info
    }
}

/** SDK adapter is separate so tests exercise the production ordering/fencing service. */
interface BillingProvider {
    suspend fun login(id: String): CustomerInfo?
    suspend fun logout()
    suspend fun customerInfo(): CustomerInfo?
    suspend fun offerings(): Offerings?
    suspend fun purchase(params: PurchaseParams): CustomerInfo
    suspend fun restore(): CustomerInfo
}

class RevenueCatBillingProvider : BillingProvider {
    override suspend fun login(id: String) = Purchases.sharedInstance.awaitLogIn(id).customerInfo
    override suspend fun logout() {
        if (!Purchases.sharedInstance.isAnonymous) Purchases.sharedInstance.awaitLogOut()
    }
    override suspend fun customerInfo() = Purchases.sharedInstance.awaitCustomerInfo()
    override suspend fun offerings() = Purchases.sharedInstance.awaitOfferings()
    override suspend fun purchase(params: PurchaseParams) = Purchases.sharedInstance.awaitPurchase(params).customerInfo
    override suspend fun restore() = Purchases.sharedInstance.awaitRestore()
}
