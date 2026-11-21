import SwiftUI
import Shared

#if os(iOS)
import UIKit
#endif

// MARK: - ParticipantsSheet

/// The poll's participant list, opened from the poll detail toolbar.
struct ParticipantsSheet: View {
    let participants: [PollParticipant]
    let isCurrentUser: (PollParticipant) -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if participants.isEmpty {
                    Text("No participants yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(participants) { participant in
                        ParticipantRow(
                            participant: participant,
                            isCurrentUser: isCurrentUser(participant)
                        )
                    }
                }
            }
            .navigationTitle("Participants")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - ShareCodeSheet

/// The poll's share code, large enough to read out or copy.
struct ShareCodeSheet: View {
    let shareCode: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(shareCode)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                    // Read one character at a time rather than as a word.
                    .accessibilityLabel(Text(shareCode.map(String.init).joined(separator: " ")))

                Text("Share this code for others to join")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                CopyButton {
                    #if os(iOS)
                    UIPasteboard.general.string = shareCode
                    #endif
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Share Code")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Participants") {
    let pollId = UUID()
    let me = UUID()
    ParticipantsSheet(
        participants: [
            PollParticipant(pollId: pollId, userId: me),
            PollParticipant(pollId: pollId, anonymousName: "Guest"),
        ],
        isCurrentUser: { $0.userId == me }
    )
}

#Preview("Share Code") {
    ShareCodeSheet(shareCode: "ABC123")
}
