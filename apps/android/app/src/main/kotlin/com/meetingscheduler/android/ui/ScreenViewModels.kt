package com.meetingscheduler.android.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.meetingscheduler.android.services.PollCreationPolls
import com.meetingscheduler.android.services.PollDetailCalendar
import com.meetingscheduler.android.services.PollDetailPolls
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.time.Clock

/**
 * Holds one screen's workflow model (F13) so that it, and the work it started, outlast the
 * Activity: a configuration change keeps the same instance in the owner's `ViewModelStore`, and
 * the work runs in [viewModelScope], which ends only when the owner is cleared (the screen is
 * popped, or the session ends; see [SessionViewModelStores]).
 *
 * The model is built when the holder is. Building throws when the model's stored state can't be
 * read, and the screen reports that from [opened] instead of holding a model.
 *
 * The holder keeps services and a clock, never an Activity, a `Context` or a `LifecycleOwner`.
 * Models still check their account key before they publish a result, which is what drops a late
 * result after an account change; the session-scoped store only releases the old model.
 */
class ScreenModelViewModel<M : Any>(
    open: () -> M,
    start: (suspend M.() -> Unit)? = null,
) : ViewModel() {
    val opened: Result<M> = runCatching(open)

    init {
        val model = opened.getOrNull()
        if (model != null && start != null) viewModelScope.launch { model.start() }
    }

    /** Runs [work] on the model in [viewModelScope], so it keeps going while the Activity is recreated. */
    fun launch(work: suspend M.() -> Unit): Job {
        val model = opened.getOrThrow()
        return viewModelScope.launch { model.work() }
    }
}

/** Opens a poll's detail screen model and starts its load once, however often the Activity is recreated. */
class PollDetailViewModelFactory(
    private val pollId: String,
    private val polls: PollDetailPolls,
    private val calendar: PollDetailCalendar,
    private val clock: Clock,
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        ScreenModelViewModel(
            open = { PollDetailModel(pollId, polls, calendar, clock) },
            start = { load() },
        ) as T
}

/** Opens the creation form's model, which restores the stored draft and any unconfirmed request. */
class PollCreationViewModelFactory(
    private val polls: PollCreationPolls,
    private val store: () -> PollCreationStore,
    private val clock: Clock,
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        ScreenModelViewModel(open = { PollCreationModel(polls, store(), clock) }) as T
}
