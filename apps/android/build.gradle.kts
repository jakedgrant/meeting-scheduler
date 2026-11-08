// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("org.jetbrains.kotlin.plugin.serialization") version "2.2.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.3" apply false
}

// Dependency locking (F24). The app's compile and runtime classpaths (debug, release and
// their unit-test and instrumented-test variants) and the plugin classpath must resolve to
// the versions in the committed lockfiles, so builds repeat and osv-scanner can read what
// ships. STRICT also fails the build when one of them resolves a module the lock does not
// list. Build-tool configurations (lint, Kotlin compiler, the test-device runner) stay
// unlocked: they don't ship, and locking them would put tool-only modules in the scan.
// To update the locks, see docs/release-checks.md ("Updating Gradle locks").
buildscript {
    configurations.classpath {
        resolutionStrategy.activateDependencyLocking()
    }
}

val lockedClasspath = Regex("(debug|release)(AndroidTest|UnitTest)?(Compile|Runtime)Classpath")

allprojects {
    dependencyLocking {
        lockMode.set(LockMode.STRICT)
    }
    configurations.matching { lockedClasspath.matches(it.name) }.configureEach {
        resolutionStrategy.activateDependencyLocking()
    }
}
