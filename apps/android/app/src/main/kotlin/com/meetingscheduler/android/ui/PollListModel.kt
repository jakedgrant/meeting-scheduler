package com.meetingscheduler.android.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.meetingscheduler.android.models.PollStatus
import com.meetingscheduler.android.services.PollListPolls

/**
 * One account's poll list screen: the join-by-code sheet, pull-to-refresh and the list commands.
 * The polls themselves stay in the process-lifetime `PollService`, which resets them when the
 * account changes; the screen reads them from it.
 *
 * A join result that arrives after the account changes is dropped.
 */
class PollListModel(private val polls: PollListPolls) {
    private val isCurrent = polls.sameAccount()

    var showJoinByCode by mutableStateOf(false)
        private set
    var joinCode by mutableStateOf("")
        private set
    var joinError by mutableStateOf<String?>(null)
        private set
    var isJoining by mutableStateOf(false)
        private set
    var isRefreshing by mutableStateOf(false)
        private set
    /** The poll a successful join found; the screen opens it and calls [openedPoll]. */
    var pollToOpen by mutableStateOf<String?>(null)
        private set

    suspend fun load() = polls.loadMyPolls()

    suspend fun refresh() {
        isRefreshing = true
        try { polls.loadMyPolls() } finally { isRefreshing = false }
    }

    suspend fun loadMore() = polls.loadMorePolls()

    suspend fun retry() = polls.retryPollLoad()

    fun showJoinSheet() {
        showJoinByCode = true
    }

    fun dismissJoinSheet() {
        showJoinByCode = false
        joinCode = ""
        joinError = null
    }

    /** Codes are six upper-case characters; longer input is ignored. */
    fun editJoinCode(text: String) {
        if (text.length <= 6) joinCode = text.uppercase()
    }

    fun openedPoll() {
        pollToOpen = null
    }

    suspend fun join() {
        isJoining = true
        joinError = null
        val code = joinCode.trim().uppercase()
        try {
            if (code.length != 6) {
                joinError = "Code must be 6 characters"
                return
            }
            val poll = polls.loadPollByCode(code)
            if (!isCurrent()) return
            when {
                poll == null -> joinError = "Poll not found. Please check the code."
                poll.status == PollStatus.CLOSED || poll.status == PollStatus.ARCHIVED ->
                    joinError = "This poll is closed and cannot accept new participants."
                else -> {
                    dismissJoinSheet()
                    pollToOpen = poll.id
                }
            }
        } finally {
            isJoining = false
        }
    }
}
