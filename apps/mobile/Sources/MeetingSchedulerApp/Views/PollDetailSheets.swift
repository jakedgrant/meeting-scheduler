import SwiftUI
import Shared

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

/// A QR code that opens the poll, and its share code large enough to read out.
struct ShareCodeSheet: View {
    let shareCode: String
    private let qrCode: QRCodeImage
    @Environment(\.dismiss) private var dismiss

    /// `pollURL` is the poll's web link, which the QR code encodes so any camera can open it.
    init(shareCode: String, pollURL: URL) {
        self.shareCode = shareCode
        qrCode = QRCodeImage(url: pollURL, accessibilityLabel: Text("QR code that opens the poll"))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Shrinks on shorter iPhones so everything fits the medium detent.
                qrCode
                    .frame(maxWidth: 228, maxHeight: 228)

                Text(shareCode)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
                    // Read one character at a time rather than as a word.
                    .accessibilityLabel(Text(shareCode.map(String.init).joined(separator: " ")))

                Text("Scan the QR code, or enter this code, to join")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
    ShareCodeSheet(shareCode: "ABC123", pollURL: URL(string: "https://example.com/polls/abc")!)
}
