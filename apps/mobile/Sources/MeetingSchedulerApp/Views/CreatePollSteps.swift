import SwiftUI
import Shared

/// A line of guidance at the top of a step's form.
struct StepIntro: View {
    let step: PollCreationModel.Step

    var body: some View {
        Section {
            Text(step.intro)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }
        .listSectionSpacing(.compact)
    }
}

// MARK: - Step 1: details

struct PollDetailsStep: View {
    @Bindable var model: PollCreationModel
    @FocusState private var isEditing: Bool

    var body: some View {
        Form {
            StepIntro(step: .details)

            Section {
                FieldHeading("Title") {
                    TextField("Title", text: $model.title, prompt: Text("Give your poll a name"))
                        .focused($isEditing)
                }

                FieldHeading("Description (optional)") {
                    TextField(
                        "Description (optional)", text: $model.description,
                        prompt: Text("Add some context"), axis: .vertical)
                        .lineLimit(3...6)
                        .focused($isEditing)
                }

                FieldHeading("Location (optional)") {
                    TextField("Location (optional)", text: $model.location, prompt: Text("Where is it?"))
                        .focused($isEditing)
                }
            } footer: {
                Text("Participants see these details when they open your poll.")
            }
        }
        .scrollDismissesKeyboard(.immediately)
        // The fields fit on screen, so without this the form never scrolls and can't dismiss the keyboard.
        .scrollBounceBehavior(.always)
        .toolbar {
            // The bottom bar sits behind the keyboard, so give the keyboard a way out.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditing = false }
            }
        }
    }
}

/// A form field under a subdued heading.
private struct FieldHeading<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            content
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Step 3: deadline

struct DeadlineStep: View {
    @Bindable var model: PollCreationModel

    private let quickPicks: [(title: LocalizedStringKey, days: Int)] = [
        ("Tomorrow", 1), ("In 2 days", 2), ("In 1 week", 7),
    ]

    var body: some View {
        Form {
            StepIntro(step: .deadline)

            Section {
                Toggle("Set response deadline", isOn: $model.hasDueDate)

                if model.hasDueDate {
                    DayPicker(
                        title: "Close responses on", selection: dueDate, range: model.now...,
                        calendar: model.calendar, layout: .stacked)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick picks")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(quickPicks.indices, id: \.self) { index in
                                quickPickButton(quickPicks[index].title, days: quickPicks[index].days)
                            }
                        }
                    }
                }
            } footer: {
                if model.hasDueDate {
                    Text(summary)
                }
            }
        }
    }

    // MARK: - Helpers

    private var dueDate: Binding<Date> {
        Binding(get: { model.dueDate ?? model.now }, set: { model.dueDate = $0 })
    }

    @ViewBuilder
    private func quickPickButton(_ title: LocalizedStringKey, days: Int) -> some View {
        let calendar = model.calendar
        let target = calendar.date(byAdding: .day, value: days, to: model.now) ?? model.now

        if calendar.isDate(dueDate.wrappedValue, inSameDayAs: target) {
            Button(title) { model.dueDate = target }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(title) { model.dueDate = target }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(.primary)
        }
    }

    private var summary: String {
        let calendar = model.calendar
        let zone = calendar.timeZone.localizedName(for: .standard, locale: .current) ?? calendar.timeZone.identifier
        let closes = DayPicker.label(for: dueDate.wrappedValue, calendar: calendar)
        var text = String(localized: "Responses close at the end of \(closes), \(zone).")
        if let first = model.firstOptionDate {
            let firstLabel = DayPicker.label(for: first, calendar: calendar)
            text += " " + String(localized: "Your first option is \(firstLabel).")
        }
        return text
    }
}

// MARK: - Step 4: Event Pass and review

struct EventPassStep: View {
    @Bindable var model: PollCreationModel

    var body: some View {
        Form {
            StepIntro(step: .eventPass)

            Section {
                Toggle("Use Event Pass", isOn: $model.useEventPass)
            } footer: {
                Text("Use the oldest available event pass for this poll. An active Pro or Team subscription takes priority and keeps your pass. Your plan and participant limit are checked when the poll is created.")
            }

            Section("Review") {
                reviewRow("Title", value: model.title, step: .details)
                reviewRow("Time options", value: timeOptionsValue, step: .timeOptions)
                reviewRow("Deadline", value: deadlineValue, step: .deadline)
                reviewRow("Location", value: model.location.isEmpty ? String(localized: "None") : model.location, step: .details)
            }

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Review

    private var timeOptionsValue: String {
        if model.isAllDay {
            let count = model.selectedDates.count
            return count == 1 ? String(localized: "1 day") : String(localized: "\(count) days")
        }
        let count = model.options.count
        return count == 1 ? String(localized: "1 option") : String(localized: "\(count) options")
    }

    private var deadlineValue: String {
        guard model.hasDueDate else { return String(localized: "None") }
        return DayPicker.label(for: model.dueDate ?? model.now, calendar: model.calendar)
    }

    private func reviewRow(_ title: LocalizedStringKey, value: String, step: PollCreationModel.Step) -> some View {
        Button {
            model.go(to: step)
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                Text(value)
                    .multilineTextAlignment(.trailing)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit")
    }
}
