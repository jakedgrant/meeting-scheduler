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
import kotlin.time.Clock

/**
 * Only the serialized defaults below read it, so a stored draft or option that lacks a date
 * still decodes. The model builds new drafts and options from its injected clock instead.
 */
private val currentSystemDate: LocalDate
    get() = Clock.System.todayIn(TimeZone.currentSystemDefault())

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
    val timeOptions: List<TimeOption> = emptyList(),
    /** The days tapped on the all-day calendar. While [isAllDay] is on, these are the poll's options. */
    val selectedDays: Set<LocalDate> = emptySet(),
    val rangeStartDate: LocalDate = currentSystemDate,
    val rangeEndDate: LocalDate = rangeStartDate,
    val rangeStartTime: LocalTime = LocalTime(9, 0), val rangeEndTime: LocalTime = LocalTime(10, 0),
    val useEventPass: Boolean = false,
) {
    companion object {
        /** An empty form whose date range starts on [today]. */
        fun starting(today: LocalDate) =
            CreationFormDraft(rangeStartDate = today)
    }
}

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

/** The screens of the creation flow, in order. [SHARE] follows a successful creation. */
enum class CreationStep { DETAILS, TIME_OPTIONS, DEADLINE, EVENT_PASS, SHARE;
    /** 1-based position, for the "Step N of 5" label. */
    val number: Int get() = ordinal + 1
}

/** What the review list on the last step shows. [deadline] is the last day responses are accepted. */
data class CreationReview(val title: String, val optionCount: Int, val deadline: LocalDate?, val location: String?)

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
    private val clock: Clock,
    private val zone: () -> TimeZone = { TimeZone.currentSystemDefault() },
) {
    private val createdForAccount = polls.creationAccountKey
    private val session = PollCreationSession(initial = store.loadPending(), persist = store::savePending)
    private var completed = false

    var draft by mutableStateOf(store.loadDraft() ?: CreationFormDraft.starting(today()))
        private set
    /** An earlier request whose outcome is unknown; it must be retried before editing. */
    var pending by mutableStateOf(session.pending)
        private set
    var isSubmitting by mutableStateOf(false)
        private set
    var errorMessage by mutableStateOf<String?>(null)
        private set
    /** The poll the server created for this account, once creation has succeeded. */
    var createdPoll by mutableStateOf<Poll?>(null)
        private set
    /** True once the poll is created for this account, so the screen can move on even if it was recreated meanwhile. */
    val created: Boolean get() = createdPoll != null

    /** The step on show. A retained, unresolved submission is retried from the last form step. */
    var step by mutableStateOf(if (session.pending != null) CreationStep.EVENT_PASS else CreationStep.DETAILS)
        private set

    /** Whether the current step has what it needs to move on. Creating the poll, not advancing, leaves the last form step. */
    val canAdvance: Boolean get() = when (step) {
        CreationStep.DETAILS -> draft.title.isNotBlank()
        CreationStep.TIME_OPTIONS -> if (draft.isAllDay) draft.selectedDays.isNotEmpty() else draft.timeOptions.isNotEmpty()
        CreationStep.DEADLINE -> true
        CreationStep.EVENT_PASS, CreationStep.SHARE -> false
    }

    /** Steps back are not offered on the first step, after creation, or while a saved submission awaits a retry. */
    val canGoBack: Boolean get() = step != CreationStep.DETAILS && step != CreationStep.SHARE && pending == null && !isSubmitting

    /** The earliest day among the options so far, for context on the deadline step. */
    val firstOptionDate: LocalDate? get() =
        if (draft.isAllDay) draft.selectedDays.minOrNull() else draft.timeOptions.minOfOrNull { it.date }

    /** The review rows: the saved request while one awaits a retry, otherwise the draft. */
    val review: CreationReview get() {
        val saved = pending?.payload
        if (saved != null) {
            return CreationReview(
                title = saved.title,
                optionCount = saved.timeOptions.size,
                deadline = saved.closesAt?.let { PollDates.dueDate(it, PollDates.zoneOrUtc(saved.timezone)) },
                location = saved.location,
            )
        }
        val form = draft
        return CreationReview(
            title = form.title.trim(),
            optionCount = if (form.isAllDay) form.selectedDays.size else form.timeOptions.size,
            deadline = if (form.hasDueDate) form.dueDate else null,
            location = form.location.trim().ifEmpty { null },
        )
    }

    fun advance() {
        if (!canAdvance) return
        CreationStep.entries.getOrNull(step.ordinal + 1)?.let { step = it; errorMessage = null }
    }

    fun goBack() {
        if (!canGoBack) return
        step = CreationStep.entries[step.ordinal - 1]
        errorMessage = null
    }

    /** Jumps back to an earlier step, as the review list does. */
    fun goTo(earlier: CreationStep) {
        if (!canGoBack || earlier.ordinal >= step.ordinal) return
        step = earlier
        errorMessage = null
    }

    private fun isCurrentAccount() = polls.creationAccountKey == createdForAccount

    /** The device time zone the poll records, such as `America/Chicago`. */
    fun zoneId(): String = zone().id

    /** Today's date in the device zone, which the poll records. */
    fun today(): LocalDate = clock.todayIn(zone())

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

    /** Selects the day on the all-day calendar, or deselects it when it was already selected. */
    fun toggleDay(day: LocalDate) = edit {
        it.copy(selectedDays = if (day in it.selectedDays) it.selectedDays - day else it.selectedDays + day)
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
            val payload = session.pending?.payload ?: run {
                // A day chosen in an earlier visit may have passed since; it is not sent.
                val days = form.selectedDays.filter { it >= today() }.sorted()
                require(!form.isAllDay || days.isNotEmpty()) { "Select at least one day." }
                PollCreationPayload(
                    title = form.title,
                    description = form.description.ifBlank { null },
                    location = form.location.ifBlank { null },
                    timezone = zone.id,
                    closesAt = if (form.hasDueDate) form.dueDate?.let { PollDates.deadline(it, zone) } else null,
                    timeOptions = if (form.isAllDay) days.map { PollDates.allDayOption(it, zone) }
                        else form.timeOptions.map { PollDates.timedOption(it.date, it.startTime, it.endTime, zone) },
                    useEventPass = form.useEventPass,
                )
            }
            require(payload.title.isNotBlank() && payload.timeOptions.isNotEmpty()) { "Enter a title and at least one time option." }
            val result = session.submit(payload, send = polls::createPoll, isCurrent = ::isCurrentAccount) ?: return false
            completed = true
            store.clearDraft()
            createdPoll = result.poll
            step = CreationStep.SHARE
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
