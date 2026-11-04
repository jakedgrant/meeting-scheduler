package com.meetingscheduler.android.ui

import kotlinx.datetime.Clock

/**
 * What the poll screens take from `AppContainer` besides the services: the clock their models
 * read and where each account's creation draft is kept.
 */
class PollScreenEnvironment(
    val clock: Clock,
    val creationStore: (accountId: String?) -> PollCreationStore,
)
