plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// Release signing (F26). Documented in docs/android-release-signing.md.
//
// Each input is read from a Gradle property (-P or ~/.gradle/gradle.properties), then
// from an environment variable of the same name. Release packaging fails unless all
// four inputs are set and KEYSTORE_FILE names an existing file. Debug builds keep the
// standard debug key and need none of this.
fun releaseSigningInput(name: String): String? =
    providers.gradleProperty(name)
        .orElse(providers.environmentVariable(name))
        .orNull
        ?.takeIf { it.isNotBlank() }

val releaseKeystoreFile: File? = releaseSigningInput("KEYSTORE_FILE")?.let { file(it) }
val releaseStorePassword = releaseSigningInput("KEYSTORE_PASSWORD")
val releaseKeyAlias = releaseSigningInput("KEY_ALIAS")
val releaseKeyPassword = releaseSigningInput("KEY_PASSWORD")

// Explicit opt-in for an unsigned release artifact that a separate, controlled step
// signs later. Never use it for builds meant for distribution as they are.
val allowUnsignedRelease =
    providers.gradleProperty("allowUnsignedRelease").orNull?.toBoolean() == true

val releaseSigningProblems: List<String> = buildList {
    val keystore = releaseKeystoreFile
    when {
        keystore == null -> add("KEYSTORE_FILE is not set")
        !keystore.isFile -> add("KEYSTORE_FILE does not exist or is not a file: $keystore")
    }
    if (releaseStorePassword == null) add("KEYSTORE_PASSWORD is not set")
    if (releaseKeyAlias == null) add("KEY_ALIAS is not set")
    if (releaseKeyPassword == null) add("KEY_PASSWORD is not set")
}

android {
    namespace = "com.meetingscheduler.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.meetingscheduler.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    signingConfigs {
        // Created only when every release signing input is present (see above).
        if (releaseSigningProblems.isEmpty()) {
            create("release") {
                storeFile = releaseKeystoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            // Never fall back to the debug key. Without complete signing material this
            // stays unset and validateReleaseSigning fails the packaging tasks, unless
            // -PallowUnsignedRelease=true was passed.
            signingConfig = if (releaseSigningProblems.isEmpty()) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }

        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += listOf(
            "-opt-in=kotlin.time.ExperimentalTime"
        )
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "META-INF/DEPENDENCIES"
            excludes += "META-INF/LICENSE"
            excludes += "META-INF/LICENSE.txt"
            excludes += "META-INF/NOTICE"
            excludes += "META-INF/NOTICE.txt"
        }
    }
    buildToolsVersion = "36.0.0"
}

// Fails release packaging when signing material is missing or incomplete. Compiling,
// linting and unit-testing the release variant still work without it.
val validateReleaseSigning by tasks.registering {
    group = "verification"
    description = "Checks that complete release signing material is configured."
    val problems = releaseSigningProblems
    val unsignedAllowed = allowUnsignedRelease
    doLast {
        if (problems.isEmpty()) return@doLast
        if (unsignedAllowed) {
            logger.warn(
                "WARNING: building an UNSIGNED release (-PallowUnsignedRelease=true). " +
                    "Sign it with the release key before distribution. Missing: " +
                    problems.joinToString("; ")
            )
            return@doLast
        }
        throw GradleException(
            buildString {
                appendLine("Release signing is not configured, so no release artifact was built.")
                problems.forEach { appendLine("  - $it") }
                appendLine("Set KEYSTORE_FILE, KEYSTORE_PASSWORD, KEY_ALIAS and KEY_PASSWORD as")
                appendLine("environment variables or Gradle properties. Release builds never fall")
                appendLine("back to the debug key. For a deliberately unsigned artifact, pass")
                appendLine("-PallowUnsignedRelease=true. See docs/android-release-signing.md.")
            }
        )
    }
}

val releaseOutputTasks = setOf(
    "assembleRelease",
    "bundleRelease",
    "packageRelease",
    "packageReleaseBundle",
    "signReleaseBundle",
    "packageReleaseUniversalApk",
)
tasks.named { it in releaseOutputTasks }.configureEach {
    dependsOn(validateReleaseSigning)
}

dependencies {
    // Core Android
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.activity:activity-compose:1.9.3")

    // Jetpack Compose
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Supabase
    implementation(platform("io.github.jan-tennert.supabase:bom:3.3.0"))
    implementation("io.github.jan-tennert.supabase:postgrest-kt")
    implementation("io.github.jan-tennert.supabase:auth-kt")
    implementation("io.github.jan-tennert.supabase:realtime-kt")
    implementation("io.github.jan-tennert.supabase:functions-kt")
    implementation("io.ktor:ktor-client-okhttp:3.2.3")

    // Kotlinx Serialization
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2")

    // Kotlinx DateTime
    implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.5.0")

    // RevenueCat
    implementation("com.revenuecat.purchases:purchases:9.1.0")

    // Google Auth (Credential Manager)
    implementation("androidx.credentials:credentials:1.6.0-rc01")
    implementation("androidx.credentials:credentials-play-services-auth:1.6.0-rc01")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")

    // Google Calendar API
    implementation("com.google.api-client:google-api-client-android:2.2.0")
    implementation("com.google.apis:google-api-services-calendar:v3-rev20220715-2.0.0")

    // Calendar integration
    implementation("androidx.work:work-runtime-ktx:2.10.0")

    // Preferences DataStore
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // Image Loading
    implementation("io.coil-kt:coil-compose:2.7.0")

    // Firebase
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-analytics-ktx")
    implementation("com.google.firebase:firebase-crashlytics-ktx")

    // Accompanist (for SwipeRefresh and other utilities)
    implementation("com.google.accompanist:accompanist-swiperefresh:0.36.0")
    implementation("com.google.accompanist:accompanist-permissions:0.36.0")
    implementation("com.google.accompanist:accompanist-systemuicontroller:0.36.0")

    // Testing
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.12.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
