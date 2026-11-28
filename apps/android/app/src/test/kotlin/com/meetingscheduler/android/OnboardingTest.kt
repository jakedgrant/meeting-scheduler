package com.meetingscheduler.android

import com.meetingscheduler.android.models.DisplayNameInput
import com.meetingscheduler.android.models.OnboardingStatus
import com.meetingscheduler.android.models.Profile
import com.meetingscheduler.android.services.AuthGateway
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.MemoryOnboardingMirror
import io.github.jan.supabase.auth.status.SessionStatus
import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.runBlocking
import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

private val codec = Json { ignoreUnknownKeys = true }
private fun onboardingSession(id: String): UserSession = codec.decodeFromString(
    """{"access_token":"token-$id","refresh_token":"refresh-$id","expires_in":3600,"token_type":"bearer","user":{"id":"$id","aud":"authenticated"}}"""
)
private val created = Instant.parse("2026-11-27T00:00:00Z")
private fun profile(id: String, completedAt: Instant? = null, name: String? = "Jake") =
    Profile(id, "$id@example.test", displayName = name, createdAt = created, updatedAt = created, onboardingCompletedAt = completedAt)

/** A gateway whose profile load and onboarding writes wait for the test to answer them. */
private class OnboardingGateway : AuthGateway {
    override val status = MutableSharedFlow<SessionStatus>()
    var load = CompletableDeferred<Profile>()
    val completions = mutableListOf<CompletableDeferred<Unit>>()
    val updates = mutableListOf<JsonObject>()
    override suspend fun loadProfile(userId: String, credential: String) = load.await()
    override suspend fun completeOnboarding(credential: String) {
        val reply = CompletableDeferred<Unit>()
        completions += reply
        reply.await()
    }
    override suspend fun updateProfile(userId: String, credential: String, updates: JsonObject): Profile {
        this.updates += updates
        return profile(userId, name = (updates["display_name"] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content)
    }
    override suspend fun awaitInitialization() {}
    override suspend fun exchangeCode(code: String, isCurrent: () -> Boolean) = error("unused")
    override suspend fun googleSession(idToken: String, nonce: String?) = error("unused")
    override suspend fun startMagicLink(email: String, redirectUrl: String, isCurrent: () -> Boolean) {}
    override suspend fun startBrowserGoogle(redirectUrl: String, isCurrent: () -> Boolean) {}
    override suspend fun signOut(previous: UserSession?) {}
    override suspend fun importSession(session: UserSession, isCurrent: () -> Boolean) {}
    suspend fun signIn(id: String) { status.emit(SessionStatus.Authenticated(onboardingSession(id))) }
}

class OnboardingTest {
    private class Offline : Exception()

    private fun harness(mirror: MemoryOnboardingMirror = MemoryOnboardingMirror(), retries: MutableList<Int> = mutableListOf()) =
        createApplicationScope(Dispatchers.Unconfined).let { scope ->
            val gateway = OnboardingGateway()
            Triple(scope, gateway, AuthService(scope, null, gateway, kotlin.time.Clock.System,
                onboardingMirror = mirror, retryDelay = { retries += it }))
        }

    @Test fun displayNamesAreLimitedTrimmedAndBlankIsNone() {
        assertEquals(DisplayNameInput.MAX_LENGTH, DisplayNameInput.limited("a".repeat(45)).length)
        assertEquals("Jake Grant", DisplayNameInput.stored("  Jake Grant \n"))
        assertNull(DisplayNameInput.stored("   "))
    }

    @Test(timeout = 15000) fun firstSignInWaitsForTheServerProfileThenRequiresOnboarding() = runBlocking {
        val (scope, gateway, auth) = harness()
        gateway.signIn("A")
        assertEquals(OnboardingStatus.UNDETERMINED, auth.onboardingStatus)
        gateway.load.complete(profile("A"))
        assertEquals(OnboardingStatus.REQUIRED, auth.onboardingStatus)
        scope.cancel()
    }

    @Test(timeout = 15000) fun serverCompletionSkipsOnboardingAndIsMirrored() = runBlocking {
        val mirror = MemoryOnboardingMirror()
        val (scope, gateway, auth) = harness(mirror)
        gateway.signIn("A")
        gateway.load.complete(profile("A", completedAt = created))
        assertEquals(OnboardingStatus.NOT_REQUIRED, auth.onboardingStatus)
        assertEquals(true, mirror.isComplete("A"))
        assertEquals(0, gateway.completions.size)
        scope.cancel()
    }

    @Test(timeout = 15000) fun mirroredCompletionSkipsOfflineAndResendsWhenTheServerLacksIt() = runBlocking {
        val mirror = MemoryOnboardingMirror().apply { markComplete("A") }
        val (scope, gateway, auth) = harness(mirror)
        gateway.signIn("A")
        assertEquals(OnboardingStatus.NOT_REQUIRED, auth.onboardingStatus)
        gateway.load.complete(profile("A"))
        assertEquals(1, gateway.completions.size)
        gateway.completions[0].complete(Unit)
        scope.cancel()
    }

    @Test(timeout = 15000) fun anUnreachableProfileShowsTheApp() = runBlocking {
        val (scope, gateway, auth) = harness()
        gateway.signIn("A")
        gateway.load.completeExceptionally(Offline())
        assertEquals(OnboardingStatus.NOT_REQUIRED, auth.onboardingStatus)
        scope.cancel()
    }

    @Test(timeout = 15000) fun completingIsImmediateAndRetriesTheServerUntilItSucceeds() = runBlocking {
        val retries = mutableListOf<Int>()
        val mirror = MemoryOnboardingMirror()
        val (scope, gateway, auth) = harness(mirror, retries)
        gateway.signIn("A")
        gateway.load.complete(profile("A"))
        auth.completeOnboarding()
        assertEquals(OnboardingStatus.NOT_REQUIRED, auth.onboardingStatus)
        assertEquals(true, mirror.isComplete("A"))
        gateway.completions[0].completeExceptionally(Offline())
        assertEquals(2, gateway.completions.size)
        gateway.completions[1].complete(Unit)
        assertEquals(listOf(0), retries)
        assertEquals(2, gateway.completions.size)
        scope.cancel()
    }

    @Test(timeout = 15000) fun completionWritesGiveUpAfterTheAttemptLimit() = runBlocking {
        val (scope, gateway, auth) = harness()
        gateway.signIn("A")
        gateway.load.complete(profile("A"))
        auth.completeOnboarding()
        for (attempt in 0 until AuthService.ONBOARDING_WRITE_ATTEMPTS) gateway.completions[attempt].completeExceptionally(Offline())
        assertEquals(AuthService.ONBOARDING_WRITE_ATTEMPTS, gateway.completions.size)
        scope.cancel()
    }

    @Test(timeout = 15000) fun anotherAccountStartsUndeterminedAndTheOldRetryStops() = runBlocking {
        val (scope, gateway, auth) = harness()
        gateway.signIn("A")
        gateway.load.complete(profile("A"))
        auth.completeOnboarding()
        gateway.load = CompletableDeferred()
        gateway.signIn("B")
        assertEquals(OnboardingStatus.UNDETERMINED, auth.onboardingStatus)
        gateway.completions[0].completeExceptionally(Offline())
        assertEquals(1, gateway.completions.size)
        scope.cancel()
    }

    @Test(timeout = 15000) fun savingANameShowsItAndStoresABlankNameAsNull() = runBlocking {
        val (scope, gateway, auth) = harness()
        gateway.signIn("A")
        gateway.load.complete(profile("A"))
        auth.saveOnboardingName("  Jacob  ")
        assertEquals("Jacob", auth.profile?.displayName)
        assertEquals(JsonPrimitive("Jacob"), gateway.updates.last()["display_name"])
        auth.saveOnboardingName("   ")
        assertNull(auth.profile?.displayName)
        assertEquals(JsonNull, gateway.updates.last()["display_name"])
        assertEquals(OnboardingStatus.REQUIRED, auth.onboardingStatus)
        scope.cancel()
    }
}
