# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# ===== GENERAL ANDROID RULES =====

# Keep all native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep custom views
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet);
}
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet, int);
}

# Keep enums
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep Parcelable
-keepclassmembers class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator CREATOR;
}

# Keep R class fields
-keepclassmembers class **.R$* {
    public static <fields>;
}

# ===== JETPACK COMPOSE =====

# Keep Compose runtime
-keep class androidx.compose.runtime.** { *; }
-keep class androidx.compose.ui.** { *; }
-keep class androidx.compose.foundation.** { *; }
-keep class androidx.compose.material3.** { *; }

# Keep Composable functions
-keep @androidx.compose.runtime.Composable class * { *; }

# ===== KOTLIN =====

# Keep Kotlin metadata
-keep class kotlin.Metadata { *; }

# Keep Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}

# ===== KOTLINX SERIALIZATION =====

-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt

-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep all serializers
-keep,includedescriptorclasses class com.meetingscheduler.android.**$$serializer { *; }
-keepclassmembers class com.meetingscheduler.android.** {
    *** Companion;
}
-keepclasseswithmembers class com.meetingscheduler.android.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep model classes for serialization
-keep class com.meetingscheduler.android.models.** { *; }

# ===== SUPABASE =====

-keep class io.github.jan.supabase.** { *; }
-keep interface io.github.jan.supabase.** { *; }

# Ktor
-keep class io.ktor.** { *; }
-keep class kotlinx.coroutines.** { *; }
-dontwarn io.ktor.**

# ===== REVENUECAT =====

-keep class com.revenuecat.purchases.** { *; }
-keep interface com.revenuecat.purchases.** { *; }

# ===== GOOGLE SERVICES =====

# Google Play Services
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# Google API Client
-keep class com.google.api.client.** { *; }
-keep class com.google.api.services.calendar.** { *; }
-dontwarn com.google.api.client.**

# Firebase
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# ===== GSON (if used by Google libraries) =====

-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
-keep class * implements com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

# ===== COIL (Image Loading) =====

-keep class coil.** { *; }
-keep interface coil.** { *; }

# OkHttp (used by Coil)
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ===== APP SPECIFIC =====

# Keep services
-keep class com.meetingscheduler.android.services.** { *; }

# Keep MainActivity
-keep class com.meetingscheduler.android.MainActivity { *; }

# ===== REMOVE LOGGING IN RELEASE =====

# Remove Log calls (except errors)
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
}

# Remove println calls
-assumenosideeffects class kotlin.io.ConsoleKt {
    public static *** println(...);
}

# ===== OPTIMIZATION =====

# Allow optimization
-optimizationpasses 5
-dontpreverify

# Aggressive optimization (uncomment if needed)
# -optimizations !code/simplification/arithmetic,!code/simplification/cast,!field/*,!class/merging/*
