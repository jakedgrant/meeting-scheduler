package com.meetingscheduler.android

import android.app.Activity
import android.app.Application
import android.content.Context
import androidx.lifecycle.LifecycleOwner
import com.meetingscheduler.android.services.AuthService
import com.meetingscheduler.android.services.CalendarService
import com.meetingscheduler.android.services.PollService
import com.meetingscheduler.android.services.PurchaseService
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.lang.reflect.Modifier

/**
 * Guards the F13 ownership rules: process-lifetime services are built once by [AppContainer]
 * from the Application and the application scope, and never capture an Activity, its
 * lifecycle, or a companion-cached instance.
 */
class ServiceLifetimeTest {
    private val services = listOf(
        AuthService::class.java,
        PollService::class.java,
        CalendarService::class.java,
        PurchaseService::class.java,
    )

    @Test
    fun servicesDoNotAcceptActivityLifecycleOrNonApplicationContext() {
        for (service in services) {
            for (constructor in service.declaredConstructors) {
                for (type in constructor.parameterTypes) {
                    val where = "${service.simpleName} constructor parameter ${type.name}"
                    assertFalse(where, Activity::class.java.isAssignableFrom(type))
                    assertFalse(where, LifecycleOwner::class.java.isAssignableFrom(type))
                    if (Context::class.java.isAssignableFrom(type)) {
                        assertTrue("$where must be the Application", Application::class.java.isAssignableFrom(type))
                    }
                }
            }
        }
    }

    @Test
    fun servicesHaveNoStaticallyCachedInstancesOrContexts() {
        val forbidden = services + listOf(Context::class.java, CoroutineScope::class.java, LifecycleOwner::class.java)
        for (service in services) {
            val staticFields = service.declaredFields.filter { Modifier.isStatic(it.modifiers) }
            for (field in staticFields) {
                assertFalse(
                    "${service.simpleName}.${field.name} statically holds ${field.type.name}",
                    forbidden.any { it.isAssignableFrom(field.type) },
                )
            }
            assertFalse(
                "${service.simpleName} still has a companion object",
                service.declaredClasses.any { it.simpleName == "Companion" },
            )
        }
    }

    @Test
    fun onlyAppContainerConstructsServices() {
        val sourceRoot = File("src/main/kotlin")
        assertTrue("run from the app module directory", sourceRoot.isDirectory)
        val construction = Regex("""(?<!class )\b(AuthService|PollService|CalendarService|PurchaseService)\(""")
        val offenders = sourceRoot.walkTopDown()
            .filter { it.isFile && it.extension == "kt" && it.name != "AppContainer.kt" }
            .flatMap { file ->
                file.readLines().mapIndexedNotNull { index, line ->
                    if (construction.containsMatchIn(line)) "${file.path}:${index + 1}: ${line.trim()}" else null
                }
            }
            .toList()
        assertEquals(emptyList<String>(), offenders)
    }

    @Test
    fun manifestRegistersTheApplicationThatOwnsTheContainer() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.contains("""android:name=".MeetingSchedulerApplication""""))
    }

    @Test
    fun applicationScopeOutlivesActivityScopeCancellation() = runBlocking {
        val applicationScope = createApplicationScope(Dispatchers.Unconfined)
        val activityScope = CoroutineScope(Job() + Dispatchers.Unconfined)
        val sessionEvents = MutableSharedFlow<String>()
        val received = java.util.Collections.synchronizedList(mutableListOf<String>())

        // Like AuthService's session listener: started while an Activity exists.
        applicationScope.launch { sessionEvents.collect { received.add(it) } }
        activityScope.launch { sessionEvents.collect { } }

        sessionEvents.emit("signed-in")
        withTimeout(5_000) { while (received.size < 1) delay(5) }
        activityScope.cancel() // Activity destroyed, e.g. on rotation.
        sessionEvents.emit("signed-out")
        withTimeout(5_000) { while (received.size < 2) delay(5) }

        assertTrue(applicationScope.isActive)
        assertEquals(listOf("signed-in", "signed-out"), received.toList())
        applicationScope.cancel()
    }

    @Test
    fun applicationScopeSurvivesAFailedChild() = runBlocking {
        val applicationScope = createApplicationScope(Dispatchers.Unconfined)
        val swallow = CoroutineExceptionHandler { _, _ -> }

        applicationScope.launch(swallow) { error("initial load failed") }
        var siblingRan = false
        applicationScope.launch { siblingRan = true }

        assertTrue(applicationScope.isActive)
        assertTrue(siblingRan)
        applicationScope.cancel()
    }
}
