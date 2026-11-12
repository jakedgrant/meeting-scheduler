import SwiftUI

/// A copy button that briefly swaps to a "Copied!" checkmark, then fades back.
struct CopyButton: View {
    let action: () -> Void
    @State private var showsCopied = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            action()
            withAnimation(.easeInOut(duration: 0.25)) { showsCopied = true }
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.4)) { showsCopied = false }
            }
        } label: {
            Label(
                showsCopied ? "Copied!" : "Copy",
                systemImage: showsCopied ? "checkmark" : "doc.on.doc"
            )
            .font(.caption)
            .contentTransition(.opacity)
        }
        .buttonStyle(.bordered)
        .onDisappear { resetTask?.cancel() }
    }
}
