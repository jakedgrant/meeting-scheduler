package com.meetingscheduler.android.services

import io.github.jan.supabase.auth.user.UserSession
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.net.URI
import java.net.URLDecoder
import java.security.MessageDigest
import kotlinx.serialization.Serializable
import java.util.UUID

@Serializable
data class PendingAuthAttempt(val ownerKey: String, val process: String, val createdAt: Long, val id: String = UUID.randomUUID().toString(), val ready: Boolean = true)

interface AuthAttemptStore {
    fun read(): PendingAuthAttempt?
    fun write(attempt: PendingAuthAttempt?)
}
class MemoryAuthAttemptStore : AuthAttemptStore {
    private var value: PendingAuthAttempt? = null
    override fun read() = value
    override fun write(attempt: PendingAuthAttempt?) { value = attempt }
}

/** Process-owned; both cold and warm Activity intents enter this router. */
class AuthCallbackRouter(
    private val scope: CoroutineScope,
    private val sessionKey: () -> String,
    private val awaitReady: suspend () -> Unit,
    private val exchange: suspend (String) -> UserSession,
    private val install: suspend (UserSession) -> Unit,
    private val reportError: (String) -> Unit,
    private val attempts: AuthAttemptStore = MemoryAuthAttemptStore(),
) {
    private val delivered = linkedSetOf<String>()
    private val mutex = Mutex()
    private val process = UUID.randomUUID().toString()
    private var disposed = false
    private val tasks = mutableSetOf<kotlinx.coroutines.Job>()
    fun cancelFlow() { attempts.write(null) }
    fun beginFlow(ready: Boolean = true): String {
        val value = PendingAuthAttempt(sessionKey(), process, System.currentTimeMillis(), ready = ready)
        attempts.write(value)
        return value.id
    }
    fun completeFlow(id: String) { attempts.read()?.takeIf { it.id == id }?.let { attempts.write(it.copy(ready = true)) } }
    fun failFlow(id: String) { if (attempts.read()?.id == id) attempts.write(null) }
    fun observeBoundary(initial: Boolean) {
        val pending = attempts.read() ?: return
        // Only the initial restoration in a new process may rebind a persisted
        // attempt; every actual account boundary invalidates it durably.
        if (initial && pending.process != process && pending.ownerKey.substringBeforeLast(':') == sessionKey().substringBeforeLast(':')) {
            attempts.write(pending.copy(ownerKey = sessionKey(), process = process, ready = true))
        } else if (!initial || pending.ownerKey != sessionKey()) attempts.write(null)
    }
    private fun ownsAttempt(key: String, attemptId: String?): Boolean {
        val pending = attempts.read() ?: return false
        return pending.ready && pending.id == attemptId && pending.ownerKey == key && pending.process == process && System.currentTimeMillis() - pending.createdAt in 0..900_000
    }
    fun dispose() { disposed = true; tasks.toList().forEach { it.cancel() }; tasks.clear() }


    fun route(url: String): Boolean {
        if (disposed) return false
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        if (uri.scheme != "meetingscheduler" || uri.host != "auth" || uri.path != "/callback" ||
            uri.port != -1 || uri.userInfo != null || uri.fragment != null) return false
        // Never retain credentials in logs or the replay cache.
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
        if (!delivered.add(fingerprint)) return true
        while (delivered.size > 64) delivered.remove(delivered.first())
        var receivedKey = sessionKey()
        val pending = attempts.read()
        val attemptId = pending?.id
        val coldAttempt = pending?.process?.let { it != process } == true
        var consumed = false
        val task = scope.launch {
            // Cold intents may arrive before storage restoration. Bind ownership after
            // readiness only if no transition occurred while waiting; never replace B.
            try {
                awaitReady()
                while (attempts.read()?.let { it.id == attemptId && !it.ready && System.currentTimeMillis() - it.createdAt < 900_000 } == true) {
                    kotlinx.coroutines.delay(10)
                }
                if (coldAttempt && ownsAttempt(sessionKey(), attemptId)) receivedKey = sessionKey()
                if (sessionKey() != receivedKey) return@launch
                val currentAttempt = attempts.read()
                if (currentAttempt != null && currentAttempt.id == attemptId && currentAttempt.ownerKey == receivedKey && System.currentTimeMillis() - currentAttempt.createdAt !in 0..900_000) {
                    attempts.write(null)
                    reportError("Your sign-in link expired. Request a new sign-in link.")
                    return@launch
                }
                if (!ownsAttempt(receivedKey, attemptId)) return@launch
                mutex.withLock {
                    if (sessionKey() != receivedKey || !ownsAttempt(receivedKey, attemptId)) return@withLock
                    val values = uri.rawQuery.orEmpty().split('&').filter { it.isNotEmpty() }.map {
                        val pair = it.split('=', limit = 2)
                        URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8")
                    }.groupBy({ it.first }, { it.second })
                    if (values.any { it.value.size != 1 }) throw IllegalArgumentException()
                    if (values.containsKey("error")) {
                        attempts.write(null)
                        reportError("Sign-in was cancelled or the link expired. Request a new sign-in link.")
                        return@withLock
                    }
                    val code = values["code"]?.singleOrNull()?.takeIf { it.isNotBlank() && it.length <= 4096 }
                        ?: throw IllegalArgumentException()
                    val session = exchange(code) // SDK validates one-time code + persisted PKCE verifier.
                    if (sessionKey() == receivedKey && ownsAttempt(receivedKey, attemptId)) {
                        consumed = true
                        attempts.write(null)
                        install(session)
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) {
                if (sessionKey() == receivedKey && (ownsAttempt(receivedKey, attemptId) || (consumed && attempts.read() == null))) reportError("Sign-in could not be completed. Request a new sign-in link.")
            }
        }
        tasks += task
        task.invokeOnCompletion { tasks -= task }
        return true
    }
}
