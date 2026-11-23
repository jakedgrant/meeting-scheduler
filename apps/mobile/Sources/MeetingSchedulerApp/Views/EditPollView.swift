import SwiftUI
import Shared

/// Edits details without replacing time options or participants' availability.
struct EditPollView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appClock) private var clock
    @Bindable var model: PollDetailModel
    @State private var draft: PollEditDraft
    @State private var showDiscardConfirmation = false
    private let timeZone: TimeZone

    init(poll: Poll, model: PollDetailModel) {
        self.model = model
        _draft = State(initialValue: PollEditDraft(poll: poll))
        timeZone = TimeZone(identifier: poll.timezone) ?? .gmt
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Poll details") {
                    TextField("Title", text: $draft.title)
                    TextField("Description (optional)", text: $draft.description, axis: .vertical)
                        .lineLimit(3...6)
                    TextField("Location (optional)", text: $draft.location)
                }
                Section {
                    Toggle("Set response deadline", isOn: hasDeadline)
                    if draft.closesAt != nil {
                        DatePicker("Close responses", selection: deadline, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, timeZone)
                    }
                } header: {
                    Text("Response deadline")
                } footer: {
                    Text("Deadline times use \(timeZone.identifier). Editing the deadline does not reopen a closed poll.")
                }
                if let error = draft.validationError(now: clock.now) ?? model.editError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .disabled(model.isChangingPoll)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Poll")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft.hasChanges { showDiscardConfirmation = true }
                        else { dismiss() }
                    }
                    .disabled(model.isChangingPoll)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.updatePoll(draft) { dismiss() }
                    } label: {
                        if model.isChangingPoll {
                            ProgressView().accessibilityLabel("Saving changes")
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!model.canMutatePoll || !draft.hasChanges || draft.validationError(now: clock.now) != nil)
                }
            }
            .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { }
            }
            .interactiveDismissDisabled(draft.hasChanges || model.isChangingPoll)
        }
    }

    private var hasDeadline: Binding<Bool> {
        Binding(get: { draft.closesAt != nil }, set: { enabled in
            draft.closesAt = enabled ? clock.now.addingTimeInterval(86_400) : nil
        })
    }

    private var deadline: Binding<Date> {
        Binding(get: { draft.closesAt ?? clock.now }, set: { draft.closesAt = $0 })
    }
}
