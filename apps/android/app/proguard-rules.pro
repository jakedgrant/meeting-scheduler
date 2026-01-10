# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# Keep Supabase classes
-keep class io.github.jan.supabase.** { *; }

# Keep RevenueCat classes
-keep class com.revenuecat.purchases.** { *; }

# Keep Kotlinx Serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt

-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

-keep,includedescriptorclasses class com.meetingscheduler.android.**$$serializer { *; }
-keepclassmembers class com.meetingscheduler.android.** {
    *** Companion;
}
-keepclasseswithmembers class com.meetingscheduler.android.** {
    kotlinx.serialization.KSerializer serializer(...);
}
