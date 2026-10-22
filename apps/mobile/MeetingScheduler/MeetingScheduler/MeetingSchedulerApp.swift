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

    init() {
        // Initialize services on app launch
        // PurchaseService initializes automatically when shared is accessed
        _ = PurchaseService.shared
    }

    var body: some Scene {
        WindowGroup {
            MeetingSchedulerApp.ContentView()
                .onOpenURL { url in
                    // Handle OAuth callback deep links
                    Task {
                        await AuthService.shared.handleDeepLink(url: url)
                    }
                }
        }
    }
}
