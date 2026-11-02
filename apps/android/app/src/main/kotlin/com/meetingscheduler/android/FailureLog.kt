package com.meetingscheduler.android

import android.util.Log

/**
 * Records failures for diagnosis without exposing what they contain.
 *
 * An exception's message can hold URLs, identifiers and server responses, so
 * release logs show only the operation and the exception's class.
 */
internal object FailureLog {
    fun record(tag: String, operation: String, error: Throwable) {
        Log.w(tag, summary(operation, error))
        if (BuildConfig.DEBUG) Log.d(tag, operation, error)
    }

    fun summary(operation: String, error: Throwable): String = "$operation: ${error.javaClass.name}"
}
