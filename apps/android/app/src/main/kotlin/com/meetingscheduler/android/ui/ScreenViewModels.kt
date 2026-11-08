package com.meetingscheduler.android.ui

import androidx.compose.runtime.Composable
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.meetingscheduler.android.services.PollCreationPolls
import com.meetingscheduler.android.services.PollDetailCalendar
import com.meetingscheduler.android.services.PollDetailPolls
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.time.Clock

/**
 * Holds one screen's workflow model (F13) so that it, and the work it started, outlast the
 * Activity: a configuration change keeps the same instance in the owner's `ViewModelStore`, and
 * the work runs in [viewModelScope], which ends only when the owner is cleared.
 *
 * Under Navigation Compose that owner is the screen's `NavBackStackEntry`: each `composable {}`
 * destination provides its entry as `LocalViewModelStoreOwner`, so [pollDetailHolder] and
 * [pollCreationHolder] resolve to the entry's store. That store is nested in the session store
 * only because `NavHost` hands `navController.setViewModelStore` the `LocalViewModelStoreOwner`
 * that `ContentView` provides (see [SessionViewModelStores]). The store is cleared when the entry
 * is popped, and when the session ends because the session store clears its nav entries.
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
    private val start: (suspend M.() -> Unit)? = null,
) : ViewModel() {
    val opened: Result<M> = runCatching(open)

    /** Set while a child screen covers this one, so that returning refreshes the model. */
    private var refreshOnReturn = false

    /** The running start work; a refresh cancels it so that no stage of an older load can interleave. */
    private var startJob: Job? = null

    init {
        val model = opened.getOrNull()
        if (model != null && start != null) startJob = viewModelScope.launch { model.start() }
    }

    /** Records that a child screen is about to cover this one. */
    fun coverWithChild() {
        refreshOnReturn = true
    }

    /**
     * Called each time the entry resumes. The first resume, and one after a configuration change,
     * find nothing recorded and do nothing, because the start work ran when the holder was built.
     * A resume after [coverWithChild] cancels any start work still running and runs it again,
     * so only one load is ever live; the model's generation and account checks still apply.
     */
    fun resumed(): Job? {
        val model = opened.getOrNull() ?: return null
        val work = start ?: return null
        if (!refreshOnReturn) return null
        refreshOnReturn = false
        startJob?.cancel()
        return viewModelScope.launch { model.work() }.also { startJob = it }
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

/** The detail holder for [pollId] in the current `LocalViewModelStoreOwner`, keyed by poll and account. */
@Composable
fun pollDetailHolder(
    pollId: String,
    polls: PollDetailPolls,
    calendar: PollDetailCalendar,
    clock: Clock,
): ScreenModelViewModel<PollDetailModel> =
    viewModel(
        key = "poll-detail/$pollId/${polls.creationAccountKey}",
        factory = PollDetailViewModelFactory(pollId, polls, calendar, clock),
    )

/** The creation holder in the current `LocalViewModelStoreOwner`, keyed by account. */
@Composable
fun pollCreationHolder(
    polls: PollCreationPolls,
    store: () -> PollCreationStore,
    clock: Clock,
): ScreenModelViewModel<PollCreationModel> =
    viewModel(
        key = "poll-creation/${polls.creationAccountKey}",
        factory = PollCreationViewModelFactory(polls, store, clock),
    )

/** Refreshes [holder] when its entry resumes after a child screen covered it (see [ScreenModelViewModel.resumed]). */
@Composable
fun RefreshOnReturn(holder: ScreenModelViewModel<*>) {
    LifecycleResumeEffect(holder) {
        holder.resumed()
        onPauseOrDispose {}
    }
}
