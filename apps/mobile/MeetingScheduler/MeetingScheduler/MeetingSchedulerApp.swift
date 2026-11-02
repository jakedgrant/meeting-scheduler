//
//  MeetingSchedulerApp.swift
//  MeetingScheduler
//
//  Created by Jake Grant on 12/31/25.
//

import SwiftUI
import MeetingSchedulerApp
import Shared

@main
struct MeetingSchedulerAppMain: App {
    private let services = AppServices.live()

    var body: some Scene {
        WindowGroup {
            MeetingSchedulerApp.AppRootView(services: services)
        }
    }
}
