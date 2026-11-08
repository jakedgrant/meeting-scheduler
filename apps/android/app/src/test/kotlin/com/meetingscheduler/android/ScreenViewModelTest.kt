package com.meetingscheduler.android

import android.content.Context
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.Snapshot
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollCreationPolls
import com.meetingscheduler.android.services.PollDetailCalendar
import com.meetingscheduler.android.services.PollDetailPolls
import com.meetingscheduler.android.ui.CreationFormDraft
import com.meetingscheduler.android.ui.PollCreationModel
import com.meetingscheduler.android.ui.PollCreationStore
import com.meetingscheduler.android.ui.PollCreationViewModelFactory
import com.meetingscheduler.android.ui.PollDetailModel
import com.meetingscheduler.android.ui.PollDetailViewModelFactory
import com.meetingscheduler.android.ui.ScreenModelFactory
import com.meetingscheduler.android.ui.ScreenModelViewModel
import com.meetingscheduler.android.ui.SessionViewModelStores
import com.meetingscheduler.android.ui.TimeOption
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import kotlin.time.Clock

/**
 * The screen models are held by ViewModels (F13): the same instance and its work survive
 * Activity recreation, clearing the store cancels the work, and a session change still drops
 * the previous session's models and results (F12).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ScreenViewModelTest {
    private val stamp = Instant.parse("2026-11-04T00:00:00Z")
    private val clock = object : Clock { override fun now() = Instant.parse("2026-11-05T12:00:00Z") }
    private val poll = Poll("poll", "owner", "Planning", status = PollStatus.ACTIVE, timezone = "America/Chicago",
        createdAt = stamp, updatedAt = stamp)
    private val option = PollTimeOption("first", "poll", Instant.parse("2026-11-10T15:00:00Z"), Instant.parse("2026-11-10T16:00:00Z"), createdAt = stamp)
    private val detail = PollDetail(poll, listOf(option), emptyList(), emptyList())

    @Before fun useTestMain() = Dispatchers.setMain(UnconfinedTestDispatcher())
    @After fun resetMain() = Dispatchers.resetMain()

    private class DetailPolls(val load: suspend () -> PollDetail) : PollDetailPolls {
        override var creationAccountId: String? = "account"
        var generation = 1
        var loads = 0
        override val creationAccountKey get() = "$creationAccountId:$generation"
        override fun availabilitySession(pollId: String) = AvailabilitySaveSession { "request" }
        override suspend fun loadPollDetail(pollId: String): PollDetail { loads += 1; return load() }
        override suspend fun joinPoll(pollId: String): PollParticipant = error("unexpected")
        override suspend fun getAvailability(pollId: String): AvailabilitySnapshot = error("unexpected")
        override suspend fun saveAvailability(pollId: String, request: AvailabilitySaveRequest): AvailabilitySnapshot = error("unexpected")
        override suspend fun updatePollStatus(pollId: String, status: PollStatus) {}
        override suspend fun finalizePoll(pollId: String, timeOptionId: String): Poll = error("unexpected")
    }

    private object NoCalendar : PollDetailCalendar {
        override val calendarError: String? = null
        override suspend fun refreshGoogleCalendarConnection() {}
        override suspend fun checkPollConflicts(options: List<PollTimeOption>, pollTimeZone: String) = CalendarCheck.NONE
    }

    private class MemoryStore : PollCreationStore {
        var draft: CreationFormDraft? = null
        override fun loadDraft() = draft
        override fun saveDraft(draft: CreationFormDraft) { this.draft = draft }
        override fun clearDraft() { draft = null }
        override fun loadPending(): PollCreationRequest? = null
        override fun savePending(request: PollCreationRequest?) {}
    }

    private class CreationPolls(val send: suspend () -> PollCreationResult) : PollCreationPolls {
        override val creationAccountId = "account"
        override val creationAccountKey = "account:1"
        override suspend fun createPoll(request: PollCreationRequest) = send()
    }

    @Suppress("UNCHECKED_CAST")
    private fun detailHolder(store: ViewModelStore, polls: DetailPolls) =
        ViewModelProvider(store, PollDetailViewModelFactory("poll", polls, NoCalendar, clock))["detail", ScreenModelViewModel::class.java]
            as ScreenModelViewModel<PollDetailModel>

    @Suppress("UNCHECKED_CAST")
    private fun creationHolder(store: ViewModelStore, polls: CreationPolls, draft: MemoryStore) =
        ViewModelProvider(store, PollCreationViewModelFactory(polls, { draft }, clock))["creation", ScreenModelViewModel::class.java]
            as ScreenModelViewModel<PollCreationModel>

    @Test fun theSameStoreReturnsTheSameHolderAndLoadsOnce() {
        val store = ViewModelStore()
        val polls = DetailPolls { detail }
        val first = detailHolder(store, polls)
        // A recreated Activity builds a new factory and provider over the retained store.
        val second = detailHolder(store, polls)
        assertSame(first, second)
        assertSame(first.opened.getOrThrow(), second.opened.getOrThrow())
        assertEquals(1, polls.loads)
        assertEquals(poll, second.opened.getOrThrow().poll)
    }

    @Test fun aLoadInFlightFinishesAfterTheActivityIsRecreated() {
        val store = ViewModelStore()
        val reply = CompletableDeferred<PollDetail>()
        val polls = DetailPolls { reply.await() }
        val before = detailHolder(store, polls).opened.getOrThrow()
        assertTrue(before.isLoading)
        val after = detailHolder(store, polls).opened.getOrThrow()
        reply.complete(detail)
        assertSame(before, after)
        assertEquals(poll, after.poll)
        assertFalse(after.isLoading)
        assertEquals(1, polls.loads)
    }

    @Test fun clearingTheStoreCancelsTheWork() {
        val store = ViewModelStore()
        var cancelled = false
        val polls = DetailPolls { try { CompletableDeferred<PollDetail>().await() } finally { cancelled = true } }
        val model = detailHolder(store, polls).opened.getOrThrow()
        assertFalse(cancelled)
        store.clear()
        assertTrue(cancelled)
        assertNull(model.poll)
    }

    @Test fun workLaunchedOnTheHolderIsCancelledWhenItIsCleared() {
        val store = ViewModelStore()
        var cancelled = false
        val polls = DetailPolls { detail }
        val holder = detailHolder(store, polls)
        val job = holder.launch { try { CompletableDeferred<Unit>().await() } finally { cancelled = true } }
        assertTrue(job.isActive)
        store.clear()
        assertTrue(cancelled)
        assertTrue(job.isCancelled)
    }

    @Test fun aDetailThatArrivesAfterTheAccountChangesIsStillDropped() {
        val store = ViewModelStore()
        val reply = CompletableDeferred<PollDetail>()
        val polls = DetailPolls { reply.await() }
        val model = detailHolder(store, polls).opened.getOrThrow()
        polls.generation = 2
        reply.complete(detail)
        assertNull(model.poll)
    }

    @Test fun aCreationInFlightFinishesAfterTheActivityIsRecreated() {
        val store = ViewModelStore()
        val draft = MemoryStore()
        val reply = CompletableDeferred<PollCreationResult>()
        val polls = CreationPolls { reply.await() }
        val before = creationHolder(store, polls, draft)
        before.opened.getOrThrow().edit {
            it.copy(title = "Planning", timeOptions = listOf(TimeOption("one", LocalDate(2026, 11, 10), LocalTime(9, 0), LocalTime(10, 0))))
        }
        before.launch { submit() }
        assertTrue(before.opened.getOrThrow().isSubmitting)
        val after = creationHolder(store, polls, draft)
        assertSame(before, after)
        assertEquals("Planning", after.opened.getOrThrow().draft.title)
        reply.complete(PollCreationResult(poll, listOf(option), entitlement = "free"))
        assertTrue(after.opened.getOrThrow().created)
        assertNull(draft.draft)
    }

    @Test fun clearingTheStoreCancelsACreationInFlight() {
        val store = ViewModelStore()
        var cancelled = false
        val polls = CreationPolls { try { CompletableDeferred<PollCreationResult>().await() } finally { cancelled = true } }
        val holder = creationHolder(store, polls, MemoryStore())
        holder.opened.getOrThrow().edit {
            it.copy(title = "Planning", timeOptions = listOf(TimeOption("one", LocalDate(2026, 11, 10), LocalTime(9, 0), LocalTime(10, 0))))
        }
        holder.launch { submit() }
        store.clear()
        assertTrue(cancelled)
        assertFalse(holder.opened.getOrThrow().created)
    }

    @Test fun resumingWithoutAChildScreenDoesNotReload() {
        val polls = DetailPolls { detail }
        val holder = detailHolder(ViewModelStore(), polls)
        // The first resume, and one after a configuration change, find nothing recorded.
        assertNull(holder.resumed())
        assertNull(holder.resumed())
        assertEquals(1, polls.loads)
    }

    @Test fun returningFromAChildScreenReloadsOnce() {
        val polls = DetailPolls { detail }
        val holder = detailHolder(ViewModelStore(), polls)
        holder.coverWithChild()
        assertNotNull(holder.resumed())
        assertEquals(2, polls.loads)
        assertNull(holder.resumed())
        assertEquals(2, polls.loads)
    }

    @Test fun aReloadThatOverlapsAnEarlierLoadSupersedesIt() {
        val first = CompletableDeferred<PollDetail>()
        val second = CompletableDeferred<PollDetail>()
        val replies = ArrayDeque(listOf(first, second))
        val polls = DetailPolls { replies.removeFirst().await() }
        val holder = detailHolder(ViewModelStore(), polls)
        val model = holder.opened.getOrThrow()
        holder.coverWithChild()
        holder.resumed()
        val stale = detail.copy(poll = poll.copy(title = "Stale"))
        first.complete(stale)
        assertTrue(first.isCompleted)
        assertNull(model.poll)
        second.complete(detail)
        assertEquals("Planning", model.poll?.title)
        assertFalse(model.isLoading)
    }

    @Test fun aReloadCancelsALoadStillRunning() {
        var cancelled = false
        val replies = ArrayDeque(listOf<suspend () -> PollDetail>(
            { try { CompletableDeferred<PollDetail>().await() } finally { cancelled = true } },
            { detail },
        ))
        val polls = DetailPolls { replies.removeFirst()() }
        val holder = detailHolder(ViewModelStore(), polls)
        holder.coverWithChild()
        holder.resumed()
        assertTrue(cancelled)
        assertEquals(poll, holder.opened.getOrThrow().poll)
    }

    @Test fun aReloadAfterTheAccountChangesIsDropped() {
        val polls = DetailPolls { detail }
        val holder = detailHolder(ViewModelStore(), polls)
        val model = holder.opened.getOrThrow()
        val reply = CompletableDeferred<PollDetail>()
        val later = DetailPolls { reply.await() }
        val laterHolder = detailHolder(ViewModelStore(), later)
        laterHolder.coverWithChild()
        laterHolder.resumed()
        later.generation = 2
        reply.complete(detail)
        assertNull(laterHolder.opened.getOrThrow().poll)
        assertEquals(poll, model.poll)
    }

    @Test fun aModelThatCannotBeOpenedIsReportedInsteadOfThrown() {
        val holder = ScreenModelViewModel<Any>(open = { error("unreadable") })
        assertTrue(holder.opened.isFailure)
    }

    @Test fun aSessionKeepsItsStoreUntilTheGenerationChanges() {
        val generation = mutableStateOf(1L)
        val stores = SessionViewModelStores { generation.value }
        val first = stores.storeOwnerFor(1)
        assertSame(first, stores.storeOwnerFor(1))
        assertNotSame(first, stores.storeOwnerFor(2))
    }

    @Test fun aNewGenerationClearsThePreviousSessionsModels() {
        val generation = mutableStateOf(1L)
        val stores = SessionViewModelStores { generation.value }
        var cancelled = false
        val polls = DetailPolls { try { CompletableDeferred<PollDetail>().await() } finally { cancelled = true } }
        val model = detailHolder(stores.storeOwnerFor(1).viewModelStore, polls).opened.getOrThrow()
        assertFalse(cancelled)
        // Sign-out or a new session changes the generation; nothing asks for the new store yet.
        generation.value = 2
        Snapshot.sendApplyNotifications()
        assertTrue(cancelled)
        assertNull(model.poll)
        val fresh = detailHolder(stores.storeOwnerFor(1).viewModelStore, DetailPolls { detail })
        assertNotSame(model, fresh.opened.getOrThrow())
    }

    @Test fun askingForANewGenerationClearsTheOldOneWithoutWaitingForTheObserver() {
        val stores = SessionViewModelStores { 1L }
        var cancelled = false
        val polls = DetailPolls { try { CompletableDeferred<PollDetail>().await() } finally { cancelled = true } }
        detailHolder(stores.storeOwnerFor(1).viewModelStore, polls)
        stores.storeOwnerFor(2)
        assertTrue(cancelled)
    }

    @Test fun clearingTheActivityStoreClearsEverySessionStore() {
        val activityStore = ViewModelStore()
        val stores = ViewModelProvider(activityStore, SessionViewModelStores.Factory { 1L })[SessionViewModelStores::class.java]
        var cancelled = false
        val polls = DetailPolls { try { CompletableDeferred<PollDetail>().await() } finally { cancelled = true } }
        detailHolder(stores.storeOwnerFor(1).viewModelStore, polls)
        activityStore.clear()
        assertTrue(cancelled)
    }

    @Test fun factoriesKeepNoActivityContextOrLifecycleOwner() {
        listOf(PollDetailViewModelFactory::class.java, PollCreationViewModelFactory::class.java, ScreenModelFactory::class.java, SessionViewModelStores.Factory::class.java)
            .flatMap { it.declaredFields.toList() }
            .forEach { field ->
                assertFalse("${field.declaringClass.simpleName}.${field.name}", Context::class.java.isAssignableFrom(field.type))
                assertFalse("${field.declaringClass.simpleName}.${field.name}", LifecycleOwner::class.java.isAssignableFrom(field.type))
            }
    }
}
