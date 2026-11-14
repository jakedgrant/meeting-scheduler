import SwiftUI
import Shared

/// The new-poll flow: details, time options, response deadline, then Event Pass and review.
/// Creating the poll moves to a final screen for sharing it.
struct CreatePollView: View {
    @Environment(\.pollService) private var pollService
    @Environment(\.authService) private var authService
    @Environment(\.appClock) private var clock

    /// Called with the new poll's ID when the user opens it from the final screen.
    var onViewPoll: (UUID) -> Void = { _ in }

    var body: some View {
        // The flow keeps the first model it receives.
        CreatePollFlow(
            model: PollCreationModel(auth: authService, polls: pollService, clock: clock),
            onViewPoll: onViewPoll)
    }
}

private struct CreatePollFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: PollCreationModel
    let onViewPoll: (UUID) -> Void

    init(model: PollCreationModel, onViewPoll: @escaping (UUID) -> Void) {
        _model = State(initialValue: model)
        self.onViewPoll = onViewPoll
    }

    var body: some View {
        NavigationStack {
            stepContent
                .navigationTitle(model.step == .share ? "" : model.step.title)
                .navigationSubtitle(model.step.stepLabel)
                #if os(iOS)
                .navigationBarTitleDisplayMode(model.step == .share ? .inline : .large)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(model.step == .share ? "Close" : "Cancel", systemImage: "xmark") {
                            dismiss()
                        }
                        .disabled(model.isSubmitting)
                    }

                    bottomBar
                }
        }
        .interactiveDismissDisabled(model.isSubmitting)
        .task(id: model.currentAccountId) {
            model.selectCurrentAccount()
        }
        .onAppear {
            UIDatePicker.appearance().minuteInterval = 15
        }
        .onDisappear {
            UIDatePicker.appearance().minuteInterval = 1
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .details:
            PollDetailsStep(model: model).disabled(model.isFormLocked)
        case .timeOptions:
            TimeOptionsStep(model: model).disabled(model.isFormLocked)
        case .deadline:
            DeadlineStep(model: model).disabled(model.isFormLocked)
        case .eventPass:
            EventPassStep(model: model).disabled(model.isFormLocked)
        case .share:
            if let poll = model.createdPoll {
                PollSharingStep(poll: poll)
            }
        }
    }

    // MARK: - Bottom bar

    /// Toolbar items, not views in a safe-area inset, so the system gives them Liquid Glass: it
    /// groups them, morphs them as steps swap them, and applies the scroll-edge effect beneath.
    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        if model.step != .details && model.step != .share {
            ToolbarItem(placement: .bottomBar) {
                Button(action: model.goBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(model.isSubmitting)
            }
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        ToolbarItem(placement: .bottomBar) {
            forwardButton
        }
    }

    @ViewBuilder
    private var forwardButton: some View {
        switch model.step {
        case .details, .timeOptions, .deadline:
            Button(action: model.advance) {
                Label("Continue", systemImage: "chevron.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canAdvance)
        case .eventPass:
            Button { model.create() } label: {
                if model.isSubmitting {
                    ProgressView()
                } else {
                    Label(model.mustResolvePending ? "Retry Creation" : "Create Poll", systemImage: "checkmark")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSubmit)
        case .share:
            Button {
                guard let id = model.createdPoll?.id else { return }
                dismiss()
                onViewPoll(id)
            } label: {
                Label("View Poll", systemImage: "eye")
            }
        }
    }
}

// MARK: - Step copy

extension PollCreationModel.Step {
    /// This step's place in the flow, counting the sharing screen; nil on the sharing screen itself.
    var position: Int? {
        self == .share ? nil : rawValue + 1
    }

    var stepLabel: LocalizedStringKey {
        position.map { "Step \($0) of \(Self.allCases.count)" } ?? ""
    }

    var title: LocalizedStringKey {
        switch self {
        case .details: "Poll details"
        case .timeOptions: "Time options"
        case .deadline: "Response deadline"
        case .eventPass: "Event Pass"
        case .share: "Poll created"
        }
    }

    /// A line of guidance shown at the top of the step.
    var intro: LocalizedStringKey {
        switch self {
        case .details: "What are you trying to schedule?"
        case .timeOptions: "Add the times people can vote on."
        case .deadline: "Choose when voting closes. You can skip this."
        case .eventPass: "Review your poll, then create it."
        case .share: ""
        }
    }
}

#Preview {
    CreatePollView()
        .previewServices(polls: MockPollService.empty)
}
