package com.meetingscheduler.android.models

import kotlinx.datetime.*
import kotlinx.serialization.json.*
import kotlin.time.Duration.Companion.hours

/** Raw detail fields. Unchanged deadlines keep their original instant and precision. */
data class PollEditDraft(
    val original: Poll,
    val title: String,
    val description: String,
    val location: String,
    val hasDeadline: Boolean,
    val deadlineDate: LocalDate,
    val deadlineTime: LocalTime,
) {
    companion object {
        fun from(poll: Poll, now: Instant): PollEditDraft {
            val local = (poll.closesAt ?: (now + 24.hours)).toLocalDateTime(PollDates.zoneOrUtc(poll.timezone))
            return PollEditDraft(poll, poll.title, poll.description.orEmpty(), poll.location.orEmpty(),
                poll.closesAt != null, local.date, LocalTime(local.hour, local.minute))
        }
    }

    private val deadlineChanged: Boolean
        get() {
            if (hasDeadline != (original.closesAt != null)) return true
            if (!hasDeadline) return false
            val local = original.closesAt?.toLocalDateTime(PollDates.zoneOrUtc(original.timezone)) ?: return true
            return deadlineDate != local.date || deadlineTime != LocalTime(local.hour, local.minute)
        }

    val hasChanges: Boolean
        get() = title != original.title || description != original.description.orEmpty()
            || location != original.location.orEmpty() || deadlineChanged

    fun validationError(now: Instant): String? = try { changes(now); null }
        catch (error: IllegalArgumentException) { error.message ?: "Check your poll details." }

    fun changes(now: Instant): JsonObject {
        val trimmedTitle = title.trim()
        require(trimmedTitle.isNotEmpty() && trimmedTitle.codePointCount(0, trimmedTitle.length) <= 200) {
            "Enter a title of 1 to 200 characters."
        }
        require(description.codePointCount(0, description.length) <= 10_000) { "Description must be 10,000 characters or less." }
        require(location.codePointCount(0, location.length) <= 1_000) { "Location must be 1,000 characters or less." }
        return buildJsonObject {
            if (title != original.title) put("title", trimmedTitle)
            if (description != original.description.orEmpty()) put("description", description.ifEmpty { null })
            if (location != original.location.orEmpty()) put("location", location.ifEmpty { null })
            if (deadlineChanged) {
                val deadline = if (hasDeadline) PollDates.instant(deadlineDate, deadlineTime, PollDates.zoneOrUtc(original.timezone)) else null
                require(deadline == null || deadline > now) { "Choose a response deadline in the future." }
                put("closes_at", deadline?.toString())
            }
        }
    }
}
