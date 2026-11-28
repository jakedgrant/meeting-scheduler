package com.meetingscheduler.android.models

/** Whether the signed-in account still has to see onboarding. */
enum class OnboardingStatus {
    /** The profile has not loaded yet, so it is not known. */
    UNDETERMINED,
    /** The server profile has no completion and this device has none recorded. */
    REQUIRED,
    /**
     * Completed or skipped on any device, or the profile could not be loaded. Onboarding never
     * blocks the app, so an unreachable profile shows the app and asks again on a later launch.
     */
    NOT_REQUIRED,
}

/** The rules for the display name typed during onboarding. */
object DisplayNameInput {
    const val MAX_LENGTH = 40

    /** [text] cut to [MAX_LENGTH] characters, so typing past the limit does nothing. */
    fun limited(text: String): String = text.take(MAX_LENGTH)

    /** The name to store: trimmed, with a blank name stored as null so others see "Anonymous". */
    fun stored(text: String): String? = limited(text).trim().ifEmpty { null }
}
