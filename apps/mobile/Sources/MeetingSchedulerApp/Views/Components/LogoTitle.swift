//
//  LogoTitle.swift
//  MeetingScheduler
//
//  Created by Jake Grant on 2/27/26.
//

import SwiftUI

struct LogoTitle: View {
    var body: some View {
        
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("Meetful")
                .font(.largeTitle)
                .fontWeight(.bold)
                .fontDesign(.serif)
        }
    }
}

#Preview {
    LogoTitle()
}
