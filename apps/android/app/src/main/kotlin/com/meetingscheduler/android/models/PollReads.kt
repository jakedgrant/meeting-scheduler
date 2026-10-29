package com.meetingscheduler.android.models

import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

class IncompletePollRead : Exception("This poll could not be loaded completely. Please retry.")

@Serializable
internal data class PollSummaryRow(
    val poll: Poll,
    val role: String,
    @SerialName("participant_count") val participantCount: Int,
    @SerialName("time_option_count") val timeOptionCount: Int,
    @SerialName("earliest_start") val earliestStart: Instant?,
    @SerialName("latest_start") val latestStart: Instant?,
)

@Serializable
internal data class PollSummaryPage(
    val items: List<PollSummaryRow>,
    @SerialName("has_more") val hasMore: Boolean,
    @SerialName("next_cursor") val nextCursor: String?,
    @SerialName("total_count") val totalCount: Int,
) {
    fun validate(account: String, isFirstPage: Boolean, cursors: Set<String>) {
        validatePageProgress(hasMore, nextCursor, items.size, 50, cursors)
        if (isFirstPage && hasMore != (totalCount > items.size)) throw IncompletePollRead()
        if (totalCount < items.size || items.map { it.poll.id }.toSet().size != items.size || items.any {
            it.role != (if (it.poll.creatorId == account) "owner" else "member") || it.participantCount < 0 || it.timeOptionCount < 0 ||
                (if (it.timeOptionCount == 0) it.earliestStart != null || it.latestStart != null
                else it.earliestStart == null || it.latestStart == null || it.earliestStart > it.latestStart)
        }) throw IncompletePollRead()
    }
}

@Serializable
internal data class PollDetailPage(
    val poll: Poll,
    @SerialName("time_options") val timeOptions: List<PollTimeOption>,
    val participants: List<PollParticipant>,
    @SerialName("time_option_count") val timeOptionCount: Int,
    @SerialName("participant_count") val participantCount: Int,
) {
    fun validate(pollId: String) {
        if (poll.id != pollId || timeOptions.size != timeOptionCount || participants.size != participantCount ||
            timeOptionCount > 500 || participantCount > 500 ||
            timeOptions.map { it.id }.toSet().size != timeOptionCount || participants.map { it.id }.toSet().size != participantCount ||
            timeOptions.any { it.pollId != pollId } || participants.any { it.pollId != pollId }) throw IncompletePollRead()
    }

    fun validateResponses(rows: List<AvailabilityResponse>) {
        val people = participants.map { it.id }.toSet()
        val options = timeOptions.map { it.id }.toSet()
        if (rows.map { it.id }.toSet().size != rows.size || rows.map { it.participantId to it.timeOptionId }.toSet().size != rows.size ||
            rows.any { it.participantId !in people || it.timeOptionId !in options }) throw IncompletePollRead()
    }
}

data class PollDetail(
    val poll: Poll,
    val timeOptions: List<PollTimeOption>,
    val participants: List<PollParticipant>,
    val responses: List<AvailabilityResponse>,
)

@Serializable
internal data class PollResponsePage(
    val items: List<AvailabilityResponse>,
    @SerialName("has_more") val hasMore: Boolean,
    @SerialName("next_cursor") val nextCursor: String?,
    @SerialName("total_count") val totalCount: Int?,
) {
    fun validate(cursors: Set<String>) = validatePageProgress(hasMore, nextCursor, items.size, 500, cursors)
}

private fun validatePageProgress(hasMore: Boolean, cursor: String?, count: Int, limit: Int, cursors: Set<String>) {
    if (hasMore != (cursor != null) || count > limit ||
        (cursor != null && (cursor.isBlank() || count == 0 || cursor in cursors))) throw IncompletePollRead()
}
