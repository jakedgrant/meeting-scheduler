package com.meetingscheduler.android

import android.app.Activity
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.AccountScreenAuth
import com.meetingscheduler.android.services.NativeSignInAttempt
import com.meetingscheduler.android.services.PollListPolls
import com.meetingscheduler.android.services.PollResponsesPolls
import com.meetingscheduler.android.services.ScreenBilling
import com.meetingscheduler.android.services.SettingsCalendar
import com.meetingscheduler.android.services.SignInAuth
import com.meetingscheduler.android.ui.*
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

/**
 * The poll list, responses, settings, profile, paywall and sign-in models (F13): each loads or
 * runs its commands, reports failures, drops a result that arrives after the account changed (F12)
 * and has its work cancelled when its holder's store is cleared.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RemainingScreenModelsTest {
    private val stamp = Instant.parse("2026-11-04T00:00:00Z")

    @Before fun useTestMain() = Dispatchers.setMain(UnconfinedTestDispatcher())
    @After fun resetMain() = Dispatchers.resetMain()

    @Suppress("UNCHECKED_CAST")
    private fun <M : Any> holder(store: ViewModelStore, open: () -> M, start: (suspend M.() -> Unit)? = null) =
        ViewModelProvider(store, ScreenModelFactory(open, start))["screen", ScreenModelViewModel::class.java] as ScreenModelViewModel<M>

    /** Work that never finishes on its own and records that it was cancelled. */
    private class Hang {
        var cancelled = false
        suspend fun await() { try { CompletableDeferred<Unit>().await() } finally { cancelled = true } }
    }

    // region Poll list

    private class ListPolls : PollListPolls {
        var generation = 1
        override val creationAccountId = "account"
        override val creationAccountKey get() = "account:$generation"
        override val myPolls = emptyList<Poll>()
        override val createdPolls = emptyList<Poll>()
        override val joinedPolls = emptyList<Poll>()
        override val isLoading = false
        override val isLoadingMore = false
        override val listLoadError: String? = null
        override val listTotalCount: Int? = null
        override val hasMorePolls = false
        override val pollParticipantCounts = emptyMap<String, Int>()
        override val pollTimeRanges = emptyMap<String, Pair<Instant, Instant>>()
        override fun formatTimeRange(earliest: Instant, latest: Instant) = ""
        var loads = 0
        var loadFailure: Exception? = null
        var onLoad: suspend () -> Unit = {}
        override suspend fun loadMyPolls() { loads += 1; onLoad(); loadFailure?.let { throw it } }
        override suspend fun loadMorePolls() {}
        override suspend fun retryPollLoad() {}
        var lookup: suspend (String) -> PollLookupResponse? = { null }
        override suspend fun loadPollByCode(code: String) = lookup(code)
    }

    private fun lookup(status: PollStatus) =
        PollLookupResponse(id = "found", title = "Planning", status = status, creatorId = "owner", createdAt = stamp, updatedAt = stamp, shareCode = "ABC123")

    @Test fun theListLoadsWhenItsHolderIsMadeAndOnlyOnce() {
        val store = ViewModelStore()
        val polls = ListPolls()
        holder(store, { PollListModel(polls) }, { load() })
        holder(store, { PollListModel(polls) }, { load() })
        assertEquals(1, polls.loads)
    }

    @Test fun refreshingShowsTheIndicatorAndClearsItWhenTheLoadFails() = kotlinx.coroutines.test.runTest {
        val polls = ListPolls()
        val model = PollListModel(polls)
        var during = false
        polls.onLoad = { during = model.isRefreshing }
        polls.loadFailure = IllegalStateException("offline")
        assertThrows(IllegalStateException::class.java) { kotlinx.coroutines.runBlocking { model.refresh() } }
        assertTrue(during)
        assertFalse(model.isRefreshing)
    }

    @Test fun aJoinCodeMustBeSixCharactersAndIsUpperCased() = kotlinx.coroutines.test.runTest {
        val model = PollListModel(ListPolls())
        model.editJoinCode("abc1234")
        assertEquals("", model.joinCode)
        model.editJoinCode("abc12")
        assertEquals("ABC12", model.joinCode)
        model.join()
        assertEquals("Code must be 6 characters", model.joinError)
        assertFalse(model.isJoining)
    }

    @Test fun joiningReportsAMissingAndAClosedPoll() = kotlinx.coroutines.test.runTest {
        val polls = ListPolls()
        val model = PollListModel(polls)
        model.editJoinCode("abc123")
        model.join()
        assertEquals("Poll not found. Please check the code.", model.joinError)
        polls.lookup = { lookup(PollStatus.CLOSED) }
        model.join()
        assertEquals("This poll is closed and cannot accept new participants.", model.joinError)
        assertNull(model.pollToOpen)
    }

    @Test fun joiningAnOpenPollClosesTheSheetAndAsksToOpenIt() = kotlinx.coroutines.test.runTest {
        val polls = ListPolls()
        polls.lookup = { assertEquals("ABC123", it); lookup(PollStatus.ACTIVE) }
        val model = PollListModel(polls)
        model.showJoinSheet()
        model.editJoinCode("abc123")
        model.join()
        assertEquals("found", model.pollToOpen)
        assertFalse(model.showJoinByCode)
        assertEquals("", model.joinCode)
        model.openedPoll()
        assertNull(model.pollToOpen)
    }

    @Test fun aJoinResultThatArrivesAfterTheAccountChangesIsDropped() {
        val store = ViewModelStore()
        val reply = CompletableDeferred<PollLookupResponse?>()
        val polls = ListPolls().apply { lookup = { reply.await() } }
        val holder = holder(store, { PollListModel(polls) })
        val model = holder.opened.getOrThrow()
        model.showJoinSheet()
        model.editJoinCode("abc123")
        holder.launch { join() }
        assertTrue(model.isJoining)
        polls.generation = 2
        reply.complete(lookup(PollStatus.ACTIVE))
        assertNull(model.pollToOpen)
        assertNull(model.joinError)
        assertFalse(model.isJoining)
    }

    @Test fun clearingTheStoreCancelsAListLoadAndAJoin() {
        val store = ViewModelStore()
        val load = Hang()
        val join = Hang()
        val polls = ListPolls().apply { onLoad = { load.await() }; lookup = { join.await(); null } }
        val holder = holder(store, { PollListModel(polls) }, { load() })
        holder.opened.getOrThrow().editJoinCode("abc123")
        holder.launch { join() }
        store.clear()
        assertTrue(load.cancelled)
        assertTrue(join.cancelled)
    }

    // endregion

    // region Time option responses

    private class ResponsePolls(val load: suspend () -> PollDetail) : PollResponsesPolls {
        var generation = 1
        override val creationAccountId = "account"
        override val creationAccountKey get() = "account:$generation"
        var loads = 0
        override suspend fun loadPollDetail(pollId: String): PollDetail { loads += 1; return load() }
    }

    private val poll = Poll("poll", "owner", "Planning", status = PollStatus.ACTIVE, timezone = "America/Chicago",
        createdAt = stamp, updatedAt = stamp)
    private val option = PollTimeOption("first", "poll", Instant.parse("2026-11-10T15:00:00Z"), Instant.parse("2026-11-10T16:00:00Z"), createdAt = stamp)
    private fun participant(id: String, name: String) =
        PollParticipant(id = id, pollId = "poll", anonymousName = name, accessToken = "", createdAt = stamp, updatedAt = stamp)
    private fun response(id: String, participantId: String, status: AvailabilityStatus, optionId: String = "first") =
        AvailabilityResponse(id = id, participantId = participantId, timeOptionId = optionId, status = status, createdAt = stamp, updatedAt = stamp)
    private val answered = PollDetail(
        poll, listOf(option),
        listOf(participant("a", "Zed"), participant("b", "Amy"), participant("c", "Bo")),
        listOf(
            response("1", "a", AvailabilityStatus.AVAILABLE),
            response("2", "b", AvailabilityStatus.AVAILABLE),
            response("3", "c", AvailabilityStatus.MAYBE),
            response("4", "c", AvailabilityStatus.UNAVAILABLE, optionId = "other"),
        ),
    )

    @Test fun theResponsesLoadWhenTheirHolderIsMadeAndAreGroupedByAnswer() {
        val store = ViewModelStore()
        val polls = ResponsePolls { answered }
        val model = holder(store, { TimeOptionResponsesModel("poll", "first", polls) }, { load() }).opened.getOrThrow()
        assertFalse(model.isLoading)
        assertEquals(option, model.timeOption)
        assertEquals("America/Chicago", model.pollTimeZone)
        assertEquals(listOf("Amy", "Zed"), model.grouped.available.map { it.participantName })
        assertEquals(listOf("Bo"), model.grouped.maybe.map { it.participantName })
        assertTrue(model.grouped.unavailable.isEmpty())
        holder(store, { TimeOptionResponsesModel("poll", "first", polls) }, { load() })
        assertEquals(1, polls.loads)
    }

    @Test fun aFailedLoadReportsAnErrorAndRetryRecovers() = kotlinx.coroutines.test.runTest {
        var fail = true
        val polls = ResponsePolls { if (fail) throw IllegalStateException("offline") else answered }
        val model = TimeOptionResponsesModel("poll", "first", polls)
        model.load()
        assertEquals("Responses could not be loaded completely. Please retry.", model.loadError)
        assertFalse(model.isLoading)
        assertNull(model.timeOption)
        fail = false
        model.load()
        assertNull(model.loadError)
        assertEquals(option, model.timeOption)
    }

    @Test fun aLoadThatArrivesAfterTheAccountChangesIsDropped() {
        val store = ViewModelStore()
        val reply = CompletableDeferred<PollDetail>()
        val polls = ResponsePolls { reply.await() }
        val model = holder(store, { TimeOptionResponsesModel("poll", "first", polls) }, { load() }).opened.getOrThrow()
        polls.generation = 2
        reply.complete(answered)
        assertNull(model.timeOption)
        assertTrue(model.participants.isEmpty())
        assertNull(model.loadError)
    }

    @Test fun aRetryReplacesALoadStillRunning() {
        val store = ViewModelStore()
        val first = CompletableDeferred<PollDetail>()
        var calls = 0
        val polls = ResponsePolls { if (++calls == 1) first.await() else answered }
        val holder = holder(store, { TimeOptionResponsesModel("poll", "first", polls) }, { load() })
        holder.launch { load() }
        first.complete(PollDetail(poll, emptyList(), emptyList(), emptyList()))
        assertEquals(option, holder.opened.getOrThrow().timeOption)
    }

    @Test fun clearingTheStoreCancelsTheLoad() {
        val store = ViewModelStore()
        val hang = Hang()
        val polls = ResponsePolls { hang.await(); answered }
        val model = holder(store, { TimeOptionResponsesModel("poll", "first", polls) }, { load() }).opened.getOrThrow()
        assertTrue(model.isLoading)
        store.clear()
        assertTrue(hang.cancelled)
    }

    // endregion

    // region Account screens

    private class Auth : AccountScreenAuth {
        override var identityGeneration = 1L
        override var accountId: String? = "account"
        override var accountEmail: String? = "ann@example.com"
        override var profile: Profile? = Profile("account", "ann@example.com", "Ann Lee", "https://example.com/a.png", "Europe/Paris",
            Instant.parse("2026-11-04T00:00:00Z"), Instant.parse("2026-11-04T00:00:00Z"))
        override fun isCurrent(id: String?, generation: Long) = id == accountId && generation == identityGeneration
        var onSignOut: suspend () -> Unit = {}
        override suspend fun signOut() = onSignOut()
        var onUpdate: suspend () -> Unit = {}
        var updates = mutableListOf<Triple<String?, String?, String?>>()
        override suspend fun updateProfile(displayName: String?, avatarUrl: String?, timezone: String?) {
            updates += Triple(displayName, avatarUrl, timezone)
            onUpdate()
        }
    }

    private class Billing : ScreenBilling<String> {
        override var hasProAccess = false
        override var packages = emptyList<String>()
        var onLoad: suspend () -> Unit = {}
        override suspend fun loadOfferings() = onLoad()
        var onPurchase: suspend (String) -> Unit = {}
        var purchased = mutableListOf<String>()
        override suspend fun purchase(activity: Activity, pkg: String) { purchased += pkg; onPurchase(pkg) }
        var onRestore: suspend () -> Unit = {}
        override suspend fun restorePurchases() = onRestore()
    }

    private class Calendar : SettingsCalendar {
        override val calendarError: String? = null
        override val googleCalendarAccountEmail: String? = null
        override var hasCalendarPermission = false
        override val appleCalendarEnabled = false
        override val googleCalendarEnabled = false
        override val googleCalendarLoading = false
        val device = mutableListOf<Boolean>()
        val google = mutableListOf<Boolean>()
        override suspend fun setAppleCalendarEnabled(enabled: Boolean) { device += enabled }
        override suspend fun setGoogleCalendarEnabled(enabled: Boolean) { google += enabled }
    }

    @Test fun settingsShowTheAccountAndThePlan() {
        val auth = Auth()
        val billing = Billing()
        val model = SettingsModel(auth, billing, Calendar())
        assertEquals("Ann Lee", model.displayName)
        assertEquals("AL", model.initials)
        assertEquals("ann@example.com", model.email)
        assertFalse(model.hasProAccess)
        billing.hasProAccess = true
        assertTrue(model.hasProAccess)
        auth.profile = null
        assertEquals("ann@example.com", model.displayName)
        assertEquals("AN", model.initials)
        assertFalse(SettingsModel(auth, null, Calendar()).hasProAccess)
    }

    @Test fun theDeviceCalendarAsksForPermissionBeforeItIsTurnedOn() = kotlinx.coroutines.test.runTest {
        val calendar = Calendar()
        val model = SettingsModel(Auth(), null, calendar)
        var asked = 0
        model.toggleDeviceCalendar(true) { asked += 1 }
        assertEquals(1, asked)
        assertTrue(calendar.device.isEmpty())
        model.deviceCalendarPermissionResult(false)
        assertTrue(calendar.device.isEmpty())
        model.deviceCalendarPermissionResult(true)
        calendar.hasCalendarPermission = true
        model.toggleDeviceCalendar(true) { asked += 1 }
        model.toggleDeviceCalendar(false) { asked += 1 }
        model.setGoogleCalendar(true)
        assertEquals(listOf(true, true, false), calendar.device)
        assertEquals(listOf(true), calendar.google)
        assertEquals(1, asked)
    }

    @Test fun aFailedRestoreIsRecordedNotThrown() = kotlinx.coroutines.test.runTest {
        val billing = Billing().apply { onRestore = { throw IllegalStateException("offline") } }
        SettingsModel(Auth(), billing, Calendar()).restorePurchases()
    }

    @Test fun signingOutShowsProgressAndAFailureClearsIt() = kotlinx.coroutines.test.runTest {
        val auth = Auth()
        val model = SettingsModel(auth, null, Calendar())
        var during = false
        auth.onSignOut = { during = model.isSigningOut; throw IllegalStateException("offline") }
        model.signOut()
        assertTrue(during)
        assertFalse(model.isSigningOut)
    }

    @Test fun aSignOutThatEndsAfterTheAccountChangedLeavesTheNewScreenAlone() {
        val store = ViewModelStore()
        val auth = Auth()
        val reply = CompletableDeferred<Unit>()
        auth.onSignOut = { reply.await() }
        val holder = holder(store, { SettingsModel(auth, null, Calendar()) })
        holder.launch { signOut() }
        assertTrue(holder.opened.getOrThrow().isSigningOut)
        auth.accountId = "other"
        reply.complete(Unit)
        assertTrue(holder.opened.getOrThrow().isSigningOut)
    }

    @Test fun clearingTheStoreCancelsASignOutAndARestore() {
        val store = ViewModelStore()
        val signOut = Hang()
        val restore = Hang()
        val auth = Auth().apply { onSignOut = { signOut.await() } }
        val billing = Billing().apply { onRestore = { restore.await() } }
        val holder = holder(store, { SettingsModel(auth, billing, Calendar()) })
        holder.launch { signOut() }
        holder.launch { restorePurchases() }
        store.clear()
        assertTrue(signOut.cancelled)
        assertTrue(restore.cancelled)
    }

    @Test fun theProfileFormStartsFromTheProfileAndSavesTheEdits() = kotlinx.coroutines.test.runTest {
        val auth = Auth()
        val model = ProfileEditModel(auth)
        assertEquals("Ann Lee", model.displayName)
        assertEquals("Europe/Paris", model.timezone)
        model.editDisplayName(" ")
        model.editAvatarUrl("")
        model.editTimezone("UTC")
        var during = false
        auth.onUpdate = { during = model.isSaving }
        model.save()
        assertTrue(during)
        assertEquals(listOf(Triple<String?, String?, String?>(null, null, "UTC")), auth.updates)
        assertTrue(model.saved)
        assertFalse(model.isSaving)
        model.acknowledgeSaved()
        assertFalse(model.saved)
    }

    @Test fun aFailedSaveReportsTheErrorAndKeepsTheEdits() = kotlinx.coroutines.test.runTest {
        val auth = Auth().apply { onUpdate = { throw IllegalStateException("offline") } }
        val model = ProfileEditModel(auth)
        model.editDisplayName("New")
        model.save()
        assertEquals("Failed to update profile: offline", model.errorMessage)
        assertFalse(model.saved)
        assertFalse(model.isSaving)
        assertEquals("New", model.displayName)
    }

    @Test fun aSaveThatEndsAfterTheAccountChangedIsDropped() {
        val store = ViewModelStore()
        val auth = Auth()
        val reply = CompletableDeferred<Unit>()
        auth.onUpdate = { reply.await() }
        val holder = holder(store, { ProfileEditModel(auth) })
        holder.launch { save() }
        auth.identityGeneration = 2
        reply.complete(Unit)
        assertFalse(holder.opened.getOrThrow().saved)
        assertNull(holder.opened.getOrThrow().errorMessage)
    }

    @Test fun theProfileFormKeepsItsEditsAcrossARebuiltProvider() {
        val store = ViewModelStore()
        val auth = Auth()
        holder(store, { ProfileEditModel(auth) }).opened.getOrThrow().editDisplayName("Edited")
        assertEquals("Edited", holder(store, { ProfileEditModel(auth) }).opened.getOrThrow().displayName)
    }

    @Test fun clearingTheStoreCancelsASave() {
        val store = ViewModelStore()
        val hang = Hang()
        val auth = Auth().apply { onUpdate = { hang.await() } }
        holder(store, { ProfileEditModel(auth) }).launch { save() }
        store.clear()
        assertTrue(hang.cancelled)
    }

    @Test fun thePaywallLoadsThePlansWhenItsHolderIsMade() {
        val store = ViewModelStore()
        val billing = Billing().apply { packages = listOf("monthly", "yearly") }
        val model = holder(store, { PaywallModel(Auth(), billing) }, { load() }).opened.getOrThrow()
        assertFalse(model.isLoading)
        assertEquals(listOf("monthly", "yearly"), model.packages)
        model.select("yearly")
        assertEquals("yearly", model.selected)
    }

    @Test fun thePaywallWithoutBillingShowsNoPlans() = kotlinx.coroutines.test.runTest {
        val model = PaywallModel<String>(Auth(), null)
        model.load()
        assertFalse(model.isLoading)
        assertTrue(model.packages.isEmpty())
    }

    @Test fun plansThatLoadAfterTheAccountChangesAreDropped() {
        val store = ViewModelStore()
        val auth = Auth()
        val reply = CompletableDeferred<Unit>()
        val billing = Billing().apply { packages = listOf("monthly"); onLoad = { reply.await() } }
        val model = holder(store, { PaywallModel(auth, billing) }, { load() }).opened.getOrThrow()
        auth.identityGeneration = 2
        reply.complete(Unit)
        assertTrue(model.packages.isEmpty())
    }

    @Test fun aPurchaseNeedsAnActivityAndAChosenPlan() = kotlinx.coroutines.test.runTest {
        val billing = Billing()
        val model = PaywallModel(Auth(), billing)
        model.purchase(Activity())
        assertTrue(billing.purchased.isEmpty())
        model.select("monthly")
        model.purchase(null)
        assertEquals("Activity context not available", model.errorMessage)
        assertFalse(model.isPurchasing)
        assertTrue(billing.purchased.isEmpty())
    }

    @Test fun aPurchaseThatSucceedsFinishesTheScreen() = kotlinx.coroutines.test.runTest {
        val billing = Billing()
        val model = PaywallModel(Auth(), billing)
        model.select("monthly")
        var during = false
        billing.onPurchase = { during = model.isPurchasing }
        model.purchase(Activity())
        assertTrue(during)
        assertEquals(listOf("monthly"), billing.purchased)
        assertTrue(model.finished)
        assertFalse(model.isPurchasing)
    }

    @Test fun aPurchaseThatFailsReportsTheError() = kotlinx.coroutines.test.runTest {
        val billing = Billing().apply { onPurchase = { throw IllegalStateException("declined") } }
        val model = PaywallModel(Auth(), billing)
        model.select("monthly")
        model.purchase(Activity())
        assertEquals("declined", model.errorMessage)
        assertFalse(model.finished)
        assertFalse(model.isPurchasing)
    }

    @Test fun restoringFinishesOnlyWhenTheAccountHasAccess() = kotlinx.coroutines.test.runTest {
        val billing = Billing()
        val model = PaywallModel<String>(Auth(), billing)
        model.restore()
        assertEquals("No purchases to restore", model.errorMessage)
        assertFalse(model.finished)
        billing.hasProAccess = true
        model.restore()
        assertNull(model.errorMessage)
        assertTrue(model.finished)
    }

    @Test fun aPurchaseThatEndsAfterTheAccountChangedIsDropped() {
        val store = ViewModelStore()
        val auth = Auth()
        val reply = CompletableDeferred<Unit>()
        val billing = Billing().apply { onPurchase = { reply.await() } }
        val holder = holder(store, { PaywallModel(auth, billing) })
        holder.opened.getOrThrow().select("monthly")
        holder.launch { purchase(Activity()) }
        auth.accountId = "other"
        reply.complete(Unit)
        assertFalse(holder.opened.getOrThrow().finished)
    }

    @Test fun clearingTheStoreCancelsAPurchaseAndTheOfferingsLoad() {
        val store = ViewModelStore()
        val purchase = Hang()
        val load = Hang()
        val billing = Billing().apply { onPurchase = { purchase.await() }; onLoad = { load.await() } }
        val holder = holder(store, { PaywallModel(Auth(), billing) }, { load() })
        holder.opened.getOrThrow().select("monthly")
        holder.launch { purchase(Activity()) }
        store.clear()
        assertTrue(load.cancelled)
        assertTrue(purchase.cancelled)
    }

    // endregion

    // region Sign-in

    private class SignIn : SignInAuth {
        override var callbackError: String? = null
        var revision = 0L
        var current = 0L
        override fun beginNativeSignIn(): NativeSignInAttempt { revision += 1; current = revision; return attempt(revision) }
        private fun attempt(revision: Long) = NativeSignInAttempt::class.java.declaredConstructors.first()
            .apply { isAccessible = true }.newInstance(revision, null, 0L) as NativeSignInAttempt
        override fun isCurrent(attempt: NativeSignInAttempt) = attempt.revision == current
        val tokens = mutableListOf<Triple<String, String?, Long>>()
        var onGoogle: suspend () -> Unit = {}
        override suspend fun signInWithGoogle(idToken: String, nonce: String?, attempt: NativeSignInAttempt) {
            tokens += Triple(idToken, nonce, attempt.revision); onGoogle()
        }
        val links = mutableListOf<String>()
        var onLink: suspend () -> Unit = {}
        override suspend fun signInWithMagicLink(email: String) { links += email; onLink() }
        var onBrowser: suspend () -> Unit = {}
        override suspend fun signInWithGoogleBrowser() = onBrowser()
    }

    private fun signIn(auth: SignIn) = SignInModel(auth, nonces = { "raw" to "hashed" })

    @Test fun aMagicLinkNeedsAnEmailAndShowsWhenItWasSent() = kotlinx.coroutines.test.runTest {
        val auth = SignIn()
        val model = signIn(auth)
        model.signInWithMagicLink()
        assertEquals("Please enter your email", model.errorMessage)
        assertTrue(auth.links.isEmpty())
        model.editEmail("ann@example.com")
        var during = false
        auth.onLink = { during = model.isLoading }
        model.signInWithMagicLink()
        assertTrue(during)
        assertEquals(listOf("ann@example.com"), auth.links)
        assertNull(model.errorMessage)
        assertTrue(model.showMagicLinkSent)
        assertFalse(model.isLoading)
        model.dismissMagicLinkSent()
        assertFalse(model.showMagicLinkSent)
    }

    @Test fun aFailedMagicLinkAndABrowserFailureAreReported() = kotlinx.coroutines.test.runTest {
        val auth = SignIn().apply { onLink = { throw IllegalStateException("rate limited") }; onBrowser = { throw IllegalStateException("x") } }
        val model = signIn(auth)
        model.editEmail("ann@example.com")
        model.signInWithMagicLink()
        assertEquals("rate limited", model.errorMessage)
        assertFalse(model.showMagicLinkSent)
        model.signInWithGoogleBrowser()
        assertEquals("Browser sign-in could not be started.", model.errorMessage)
        assertFalse(model.isLoading)
    }

    @Test fun theCallbackErrorShowsWhenTheScreenHasNone() {
        val auth = SignIn().apply { callbackError = "link expired" }
        val model = signIn(auth)
        assertEquals("link expired", model.displayedError)
    }

    @Test fun aGoogleSignInTriesOneTapThenSignsInWithTheToken() = kotlinx.coroutines.test.runTest {
        val auth = SignIn()
        val model = signIn(auth)
        val asked = mutableListOf<Pair<String, Boolean>>()
        model.signInWithGoogle { nonce, returning -> asked += nonce to returning; "token" }
        assertEquals(listOf("hashed" to true), asked)
        assertEquals(listOf(Triple("token", "raw" as String?, 1L)), auth.tokens)
        assertNull(model.errorMessage)
        assertFalse(model.isLoading)
    }

    @Test fun aGoogleSignInFallsBackToTheButtonFlowWhenOneTapHasNoAccount() = kotlinx.coroutines.test.runTest {
        val auth = SignIn()
        val model = signIn(auth)
        val asked = mutableListOf<Boolean>()
        model.signInWithGoogle { _, returning ->
            asked += returning
            if (returning) throw GoogleCredentialUnavailable() else "token"
        }
        assertEquals(listOf(true, false), asked)
        assertEquals("token", auth.tokens.single().first)
    }

    @Test fun cancellingTheGoogleUiShowsNoError() = kotlinx.coroutines.test.runTest {
        val auth = SignIn()
        val model = signIn(auth)
        model.signInWithGoogle { _, _ -> throw GoogleCredentialCancelled() }
        assertNull(model.errorMessage)
        assertTrue(auth.tokens.isEmpty())
        assertFalse(model.isLoading)
    }

    @Test fun googleFailuresAreReportedToThePerson() = kotlinx.coroutines.test.runTest {
        val model = signIn(SignIn())
        model.signInWithGoogle { _, returning -> if (returning) throw GoogleCredentialCancelled() else throw GoogleCredentialFailed(IllegalStateException()) }
        assertEquals("Google sign-in failed. Please ensure you have a Google account on this device.", model.errorMessage)
        model.signInWithGoogle { _, _ -> throw GoogleCredentialRejected("Unexpected credential type") }
        assertEquals("Unexpected credential type", model.errorMessage)
    }

    @Test fun aSupabaseFailureIsReportedWhileTheAttemptIsCurrent() = kotlinx.coroutines.test.runTest {
        val auth = SignIn().apply { onGoogle = { throw IllegalStateException("bad token") } }
        val model = signIn(auth)
        model.signInWithGoogle { _, _ -> "token" }
        assertEquals("bad token", model.errorMessage)
    }

    @Test fun anAttemptThatAnotherAttemptReplacedShowsNothing() = kotlinx.coroutines.test.runTest {
        val auth = SignIn()
        val model = signIn(auth)
        auth.onGoogle = { auth.current = 99; throw IllegalStateException("late failure") }
        model.signInWithGoogle { _, _ -> "token" }
        assertNull(model.errorMessage)
        val second = signIn(auth)
        second.signInWithGoogle { _, returning ->
            if (returning) throw GoogleCredentialCancelled()
            auth.current = 99; throw GoogleCredentialFailed(IllegalStateException())
        }
        assertNull(second.errorMessage)
    }

    @Test fun onlyTheLatestRequestOwnsTheLoadingFlag() {
        val store = ViewModelStore()
        val first = CompletableDeferred<Unit>()
        var calls = 0
        val auth = SignIn().apply { onLink = { if (++calls == 1) first.await() } }
        val holder = holder(store, { signIn(auth) })
        val model = holder.opened.getOrThrow()
        model.editEmail("ann@example.com")
        holder.launch { signInWithMagicLink() }
        holder.launch { signInWithMagicLink() }
        assertFalse(model.isLoading)
        first.complete(Unit)
        assertFalse(model.isLoading)
        assertEquals(2, auth.links.size)
    }

    @Test fun clearingTheStoreCancelsASignInInFlight() {
        val store = ViewModelStore()
        val link = Hang()
        val google = Hang()
        val auth = SignIn().apply { onLink = { link.await() } }
        val holder = holder(store, { signIn(auth) })
        holder.opened.getOrThrow().editEmail("ann@example.com")
        holder.launch { signInWithMagicLink() }
        holder.launch { signInWithGoogle { _, _ -> google.await(); "token" } }
        store.clear()
        assertTrue(link.cancelled)
        assertTrue(google.cancelled)
        assertTrue(auth.tokens.isEmpty())
    }

    // endregion
}
