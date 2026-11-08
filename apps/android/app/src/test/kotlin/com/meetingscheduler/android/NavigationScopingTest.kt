package com.meetingscheduler.android

import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.compose.material3.TextButton
import androidx.compose.runtime.snapshots.Snapshot
import com.meetingscheduler.android.models.*
import com.meetingscheduler.android.services.PollCreationPolls
import com.meetingscheduler.android.services.PollDetailCalendar
import com.meetingscheduler.android.services.PollDetailPolls
import com.meetingscheduler.android.services.PollListPolls
import com.meetingscheduler.android.services.PollResponsesPolls
import com.meetingscheduler.android.ui.CreationFormDraft
import com.meetingscheduler.android.ui.PollCreationModel
import com.meetingscheduler.android.ui.PollCreationStore
import com.meetingscheduler.android.ui.PollListModel
import com.meetingscheduler.android.ui.PollListView
import com.meetingscheduler.android.ui.TimeOptionResponsesModel
import com.meetingscheduler.android.ui.TimeOptionResponsesView
import com.meetingscheduler.android.ui.timeOptionResponsesHolder
import com.meetingscheduler.android.ui.pollListHolder
import com.meetingscheduler.android.ui.PollDetailModel
import com.meetingscheduler.android.ui.RefreshOnReturn
import com.meetingscheduler.android.ui.ScreenModelViewModel
import com.meetingscheduler.android.ui.SessionScope
import com.meetingscheduler.android.ui.SessionViewModelStores
import com.meetingscheduler.android.ui.TimeOption
import com.meetingscheduler.android.ui.pollCreationHolder
import com.meetingscheduler.android.ui.pollDetailHolder
import kotlinx.coroutines.CompletableDeferred
import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.time.Clock

/**
 * Hosts the real scoping chain on the JVM: the Activity-scoped [SessionViewModelStores] provides
 * a store through [SessionScope], a `NavHost` nests each destination's `NavBackStackEntry` store
 * in it, and the screens resolve their holders with [pollDetailHolder] and [pollCreationHolder],
 * the functions the real screens call. The F12 guarantees depend on that chain: a new identity
 * generation clears the old entries' work at once, a popped creation form is cleared, and a
 * reopened form gets a fresh model.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = android.app.Application::class)
class NavigationScopingTest {
    @get:Rule val rule = createComposeRule()

    private val stamp = Instant.parse("2026-11-04T00:00:00Z")
    private val clock = object : Clock { override fun now() = Instant.parse("2026-11-05T12:00:00Z") }
    private val poll = Poll("poll", "owner", "Planning", status = PollStatus.ACTIVE, timezone = "America/Chicago",
        createdAt = stamp, updatedAt = stamp)
    private val detail = PollDetail(poll, emptyList(), emptyList(), emptyList())

    private class DetailPolls(val load: suspend () -> PollDetail) : PollDetailPolls {
        override var creationAccountId: String? = "account"
        override val creationAccountKey get() = "$creationAccountId:1"
        var loads = 0
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

    private class ListPolls(val load: suspend () -> Unit) : PollListPolls {
        var generation = 1
        override val creationAccountId = "account"
        override val creationAccountKey get() = "account:$generation"
        override val myPolls = emptyList<Poll>()
        override val createdPolls = emptyList<Poll>()
        override val joinedPolls = emptyList<Poll>()
        override val isLoading = false
        override val isLoadingMore = false
        override val listLoadError: String? = null
        override val listTotalCount: Int? = null
        override val hasMorePolls = false
        override val pollParticipantCounts = emptyMap<String, Int>()
        override val pollTimeRanges = emptyMap<String, Pair<Instant, Instant>>()
        override fun formatTimeRange(earliest: Instant, latest: Instant) = ""
        var loads = 0
        override suspend fun loadMyPolls() { loads += 1; load() }
        override suspend fun loadMorePolls() {}
        override suspend fun retryPollLoad() {}
        override suspend fun loadPollByCode(code: String): PollLookupResponse? = null
    }

    private class ResponsePolls(val load: suspend () -> PollDetail) : PollResponsesPolls {
        override val creationAccountId = "account"
        override val creationAccountKey = "account:1"
        var loads = 0
        override suspend fun loadPollDetail(pollId: String): PollDetail { loads += 1; return load() }
    }

    private val generation = mutableStateOf(1L)
    private lateinit var nav: NavHostController
    private var detailHolder: ScreenModelViewModel<PollDetailModel>? = null
    private var creationHolder: ScreenModelViewModel<PollCreationModel>? = null
    private var listHolder: ScreenModelViewModel<PollListModel>? = null
    private var responsesHolder: ScreenModelViewModel<TimeOptionResponsesModel>? = null

    private fun host(
        detailPolls: DetailPolls,
        creationPolls: CreationPolls,
        draft: MemoryStore = MemoryStore(),
        listPolls: ListPolls = ListPolls {},
        responsePolls: ResponsePolls = ResponsePolls { detail },
    ) {
        rule.setContent {
            val stores = viewModel<SessionViewModelStores>(
                factory = SessionViewModelStores.Factory { generation.value },
            )
            SessionScope(stores, generation.value) {
                nav = rememberNavController()
                NavHost(nav, startDestination = "list") {
                    composable("list") { Text("List") }
                    composable("detail") {
                        val holder = pollDetailHolder("poll", detailPolls, NoCalendar, clock)
                        RefreshOnReturn(holder)
                        detailHolder = holder
                        TextButton(onClick = { holder.coverWithChild(); nav.navigate("child") }) { Text("Open child") }
                    }
                    composable("child") { Text("Child") }
                    composable("polls") {
                        // The real screen: it resolves its holder from the entry's store.
                        PollListView(
                            pollService = listPolls,
                            onNavigateToPoll = { nav.navigate("child") },
                            onNavigateToCreatePoll = { nav.navigate("create") },
                            onNavigateToPaywall = {},
                        )
                        listHolder = pollListHolder(listPolls)
                    }
                    composable("responses") {
                        TimeOptionResponsesView("poll", "first", responsePolls, onNavigateBack = { nav.popBackStack() })
                        responsesHolder = timeOptionResponsesHolder("poll", "first", responsePolls)
                    }
                    composable("create") {
                        creationHolder = pollCreationHolder(creationPolls, { draft }, clock)
                        Text("Creating")
                    }
                }
            }
        }
    }

    private fun navigate(route: String) {
        rule.runOnUiThread { nav.navigate(route) }
        rule.waitForIdle()
    }

    private fun pop() {
        rule.runOnUiThread { nav.popBackStack() }
        rule.waitForIdle()
    }

    @Test fun aNewIdentityGenerationCancelsTheDetailEntrysWork() {
        var cancelled = false
        val detailPolls = DetailPolls { try { CompletableDeferred<PollDetail>().await() } finally { cancelled = true } }
        host(detailPolls, CreationPolls { error("unexpected") })
        navigate("detail")
        val before = detailHolder!!.opened.getOrThrow()
        assertTrue(before.isLoading)
        assertFalse(cancelled)

        rule.runOnUiThread { generation.value = 2 }
        rule.waitForIdle()

        assertTrue(cancelled)
        assertNull(before.poll)
    }

    @Test fun aNewIdentityGenerationClearsAnOpenCreationFormAndItsRequest() {
        var cancelled = false
        val creationPolls = CreationPolls { try { CompletableDeferred<PollCreationResult>().await() } finally { cancelled = true } }
        host(DetailPolls { detail }, creationPolls)
        navigate("create")
        val holder = creationHolder!!
        holder.opened.getOrThrow().edit {
            it.copy(title = "Planning", timeOptions = listOf(TimeOption("one", LocalDate(2026, 11, 10), LocalTime(9, 0), LocalTime(10, 0))))
        }
        rule.runOnUiThread { holder.launch { submit() } }
        assertFalse(cancelled)

        rule.runOnUiThread { generation.value = 2 }
        rule.waitForIdle()

        assertTrue(cancelled)
        assertFalse(holder.opened.getOrThrow().created)
    }

    @Test fun poppingAndReopeningTheCreationFormBuildsAFreshModel() {
        val option = PollTimeOption("first", "poll", Instant.parse("2026-11-10T15:00:00Z"), Instant.parse("2026-11-10T16:00:00Z"), createdAt = stamp)
        val creationPolls = CreationPolls { PollCreationResult(poll, listOf(option), entitlement = "free") }
        host(DetailPolls { detail }, creationPolls)
        navigate("create")
        val first = creationHolder!!
        first.opened.getOrThrow().edit {
            it.copy(title = "Planning", timeOptions = listOf(TimeOption("one", LocalDate(2026, 11, 10), LocalTime(9, 0), LocalTime(10, 0))))
        }
        rule.runOnUiThread { first.launch { submit() } }
        rule.waitForIdle()
        assertTrue(first.opened.getOrThrow().created)

        pop()
        navigate("create")

        val second = creationHolder!!
        assertNotSame(first, second)
        assertFalse(second.opened.getOrThrow().created)
    }

    @Test fun poppingTheCreationFormCancelsItsRequest() {
        var cancelled = false
        val creationPolls = CreationPolls { try { CompletableDeferred<PollCreationResult>().await() } finally { cancelled = true } }
        host(DetailPolls { detail }, creationPolls)
        navigate("create")
        val holder = creationHolder!!
        holder.opened.getOrThrow().edit {
            it.copy(title = "Planning", timeOptions = listOf(TimeOption("one", LocalDate(2026, 11, 10), LocalTime(9, 0), LocalTime(10, 0))))
        }
        rule.runOnUiThread { holder.launch { submit() } }
        assertFalse(cancelled)

        pop()

        assertTrue(cancelled)
    }

    @Test fun returningFromAChildScreenReloadsTheDetailOnce() {
        val detailPolls = DetailPolls { detail }
        host(detailPolls, CreationPolls { error("unexpected") })
        navigate("detail")
        assertEquals(1, detailPolls.loads)

        rule.onNodeWithText("Open child").performClick()
        rule.waitForIdle()
        assertEquals(1, detailPolls.loads)
        pop()

        assertEquals(2, detailPolls.loads)
        assertEquals(poll, detailHolder!!.opened.getOrThrow().poll)
    }

    @Test fun thePollListLoadsOnceWhenItsEntryOpensAndReloadsWhenItReturnsFromAChild() {
        val listPolls = ListPolls {}
        host(DetailPolls { detail }, CreationPolls { error("unexpected") }, listPolls = listPolls)
        navigate("polls")
        assertEquals(1, listPolls.loads)
        val first = listHolder!!

        navigate("child")
        assertEquals(1, listPolls.loads)
        pop()

        assertEquals(2, listPolls.loads)
        assertSame(first, listHolder)
    }

    @Test fun thePollListKeepsItsJoinSheetAcrossAChildScreen() {
        host(DetailPolls { detail }, CreationPolls { error("unexpected") })
        navigate("polls")
        rule.runOnUiThread { listHolder!!.opened.getOrThrow().showJoinSheet() }
        rule.waitForIdle()
        rule.onNodeWithText("Join by Code").assertExists()
        val model = listHolder!!.opened.getOrThrow()

        navigate("child")
        pop()

        assertSame(model, listHolder!!.opened.getOrThrow())
        assertTrue(model.showJoinByCode)
    }

    @Test fun aNewIdentityGenerationCancelsThePollListsLoad() {
        var cancelled = false
        val listPolls = ListPolls { try { CompletableDeferred<Unit>().await() } finally { cancelled = true } }
        host(DetailPolls { detail }, CreationPolls { error("unexpected") }, listPolls = listPolls)
        navigate("polls")
        assertFalse(cancelled)

        rule.runOnUiThread { generation.value = 2 }
        rule.waitForIdle()

        assertTrue(cancelled)
    }

    @Test fun aPushedResponsesScreenLoadsOnceAndIsClearedWhenItIsPopped() {
        var cancelled = false
        val reply = CompletableDeferred<PollDetail>()
        val responsePolls = ResponsePolls { try { reply.await() } finally { cancelled = true } }
        host(DetailPolls { detail }, CreationPolls { error("unexpected") }, responsePolls = responsePolls)
        navigate("polls")
        navigate("responses")
        assertEquals(1, responsePolls.loads)
        val first = responsesHolder!!.opened.getOrThrow()
        assertTrue(first.isLoading)

        pop()
        assertTrue(cancelled)

        navigate("responses")
        assertEquals(2, responsePolls.loads)
        assertNotSame(first, responsesHolder!!.opened.getOrThrow())
    }

    @Test fun aNewIdentityGenerationCancelsAPushedResponsesLoad() {
        var cancelled = false
        val responsePolls = ResponsePolls { try { CompletableDeferred<PollDetail>().await() } finally { cancelled = true } }
        host(DetailPolls { detail }, CreationPolls { error("unexpected") }, responsePolls = responsePolls)
        navigate("responses")
        assertFalse(cancelled)

        rule.runOnUiThread { generation.value = 2 }
        rule.waitForIdle()

        assertTrue(cancelled)
    }
}
