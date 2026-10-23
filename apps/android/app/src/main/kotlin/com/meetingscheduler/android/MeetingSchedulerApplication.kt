package com.meetingscheduler.android

import android.app.Application
import kotlinx.coroutines.Dispatchers

class MeetingSchedulerApplication : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(
            application = this,
            applicationScope = createApplicationScope(Dispatchers.Main.immediate),
        )
    }
}
