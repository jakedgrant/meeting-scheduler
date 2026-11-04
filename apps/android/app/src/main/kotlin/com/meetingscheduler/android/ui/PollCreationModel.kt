package com.meetingscheduler.android.ui

import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollCreationPolls
import kotlinx.coroutines.CancellationException
import kotlinx.datetime.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID

internal val currentSystemDate: LocalDate
    get() = Instant.fromEpochMilliseconds(System.currentTimeMillis()).toLocalDateTime(TimeZone.currentSystemDefault()).date

@Serializable
data class TimeOption(
    val id: String = UUID.randomUUID().toString(),
    val date: LocalDate = currentSystemDate,
    val startTime: LocalTime = LocalTime(9, 0),
    val endTime: LocalTime = LocalTime(10, 0)
)

/** The creation form as the device keeps it between visits. */
@Serializable
data class CreationFormDraft(
    val title: String = "", val description: String = "", val location: String = "",
    val hasDueDate: Boolean = false, val dueDate: LocalDate? = null,
    val isAllDay: Boolean = false, val useDateRange: Boolean = false,
    val timeOptions: List<TimeOption> = listOf(TimeOption()),
    val rangeStartDate: LocalDate = currentSystemDate,
    val rangeEndDate: LocalDate = rangeStartDate,
    val rangeStartTime: LocalTime = LocalTime(9, 0), val rangeEndTime: LocalTime = LocalTime(10, 0),
    val useEventPass: Boolean = false,
)

/** Where one account's creation draft and its unconfirmed request are kept. */
interface PollCreationStore {
    /** Throws when a stored value can't be read. */
    fun loadDraft(): CreationFormDraft?
    fun saveDraft(draft: CreationFormDraft)
    fun clearDraft()
    /** Throws when a stored value can't be read. */
    fun loadPending(): PollCreationRequest?
    /** Throws `CreationStorageFailure` when the write doesn't reach disk. */
    fun savePending(request: PollCreationRequest?)
}

/** Keeps each account's draft and pending request under its own keys in `poll_creation_v1`. */
class SharedPreferencesCreationStore(
    private val preferences: SharedPreferences,
    private val accountId: String?,
) : PollCreationStore {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val draftKey = "draft:$accountId"
    private val pendingKey = "pending:$accountId"

    override fun loadDraft() = preferences.getString(draftKey, null)?.let { json.decodeFromString<CreationFormDraft>(it) }

    /** Signed-out drafts aren't kept. */
    override fun saveDraft(draft: CreationFormDraft) {
        if (accountId != null) preferences.edit().putString(draftKey, json.encodeToString(draft)).apply()
    }

    override fun clearDraft() {
        preferences.edit().remove(draftKey).commit()
    }

    override fun loadPending() = preferences.getString(pendingKey, null)?.let { json.decodeFromString<PollCreationRequest>(it) }

    override fun savePending(request: PollCreationRequest?) {
        val edit = preferences.edit()
        if (request == null) edit.remove(pendingKey) else edit.putString(pendingKey, json.encodeToString(request))
        if (!edit.commit()) throw CreationStorageFailure()
    }
}

/**
 * One account's poll creation form. It restores and keeps the draft, builds time options, and
 * submits through `PollCreationSession`, which keeps an unconfirmed request for retry.
 *
 * The constructor throws when the stored draft or request can't be read. A result that arrives
 * after the account changes is dropped.
 */
class PollCreationModel(
    private val polls: PollCreationPolls,
    private val store: PollCreationStore,
    private val today: () -> LocalDate = { currentSystemDate },
    private val zone: () -> TimeZone = { TimeZone.currentSystemDefault() },
) {
    private val createdForAccount = polls.creationAccountKey
    private val session = PollCreationSession(initial = store.loadPending(), persist = store::savePending)
    private var completed = false

    var draft by mutableStateOf(store.loadDraft() ?: CreationFormDraft())
        private set
    /** An earlier request whose outcome is unknown; it must be retried before editing. */
    var pending by mutableStateOf(session.pending)
        private set
    var isSubmitting by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set

    private fun isCurrentAccount() = polls.creationAccountKey == createdForAccount

    /** Changes the draft and keeps it, until the poll is created. */
    fun edit(transform: (CreationFormDraft) -> CreationFormDraft) {
        draft = transform(draft)
        if (!completed) store.saveDraft(draft)
    }

    /** Turning the deadline on starts it at today when no date was chosen. */
    fun setHasDueDate(enabled: Boolean) = edit {
        it.copy(hasDueDate = enabled, dueDate = if (enabled && it.dueDate == null) today() else it.dueDate)
    }

    fun updateOption(index: Int, transform: (TimeOption) -> TimeOption) = edit {
        it.copy(timeOptions = it.timeOptions.mapIndexed { i, option -> if (i == index) transform(option) else option })
    }

    fun removeOption(index: Int) = edit {
        it.copy(timeOptions = it.timeOptions.filterIndexed { i, _ -> i != index })
    }

    /** Adds an option the day after the last one, at the same times. */
    fun addOption() = edit {
        val last = it.timeOptions.lastOrNull()
        it.copy(timeOptions = it.timeOptions + TimeOption(
            date = last?.date?.plus(1, DateTimeUnit.DAY) ?: today(),
            startTime = last?.startTime ?: LocalTime(9, 0),
            endTime = last?.endTime ?: LocalTime(10, 0),
        ))
    }

    /** Adds one option for each day of the range, at the range's times, and sorts the options. */
    fun addRangeOptions() {
        val current = draft
        if (current.rangeStartDate > current.rangeEndDate) {
            errorMessage = "Start date must be before or equal to end date"
            return
        }
        val added = generateSequence(current.rangeStartDate) { it.plus(1, DateTimeUnit.DAY) }
            .takeWhile { it <= current.rangeEndDate }
            .map { TimeOption(date = it, startTime = current.rangeStartTime, endTime = current.rangeEndTime) }
        edit {
            it.copy(timeOptions = (it.timeOptions + added).sortedWith(compareBy({ option -> option.date }, { option -> option.startTime })))
        }
        errorMessage = null
    }

    /**
     * Sends the pending request if there is one, or a new one built from the draft. Returns true
     * once the poll is created for this account.
     */
    suspend fun submit(): Boolean {
        if (isSubmitting) return false
        isSubmitting = true
        errorMessage = null
        try {
            val form = draft
            // Picker values are wall times in the device zone, which the poll records.
            val zone = zone()
            val payload = session.pending?.payload ?: PollCreationPayload(
                title = form.title,
                description = form.description.ifBlank { null },
                location = form.location.ifBlank { null },
                timezone = zone.id,
                closesAt = if (form.hasDueDate) form.dueDate?.let { PollDates.deadline(it, zone) } else null,
                timeOptions = form.timeOptions.map { option ->
                    if (form.isAllDay) PollDates.allDayOption(option.date, zone)
                    else PollDates.timedOption(option.date, option.startTime, option.endTime, zone)
                },
                useEventPass = form.useEventPass,
            )
            require(payload.title.isNotBlank() && payload.timeOptions.isNotEmpty()) { "Enter a title and at least one time option." }
            session.submit(payload, send = polls::createPoll, isCurrent = ::isCurrentAccount) ?: return false
            completed = true
            store.clearDraft()
            return true
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (isCurrentAccount()) {
                errorMessage = if (error is CreationRejected || error is IllegalArgumentException || error is CreationStorageFailure) error.message
                    else "Creation could not be confirmed. Your draft is saved. Retry to recover the original poll."
            }
            return false
        } finally {
            pending = session.pending
            isSubmitting = false
        }
    }
}
