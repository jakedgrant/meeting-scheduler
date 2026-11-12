import Foundation

/// The new-poll form for the signed-in account: its fields, the time options it builds and
/// the submission, which `PollCreationEditor` makes safe to retry.
///
/// Picker values are wall times in the calendar's zone, which the poll records as its zone
/// (docs/date-time-contract.md).
@MainActor
@Observable
public final class PollCreationModel {
    /// One time option as the pickers edit it: a date and wall times on any day.
    public struct Option: Identifiable {
        public let id = UUID()
        public var date: Date
        public var startTime: Date
        public var endTime: Date
    }

    public var title = ""
    public var description = ""
    public var location = ""
    public var dueDate: Date?
    public var hasDueDate = false
    public var isAllDay = false
    public var useDateRange = false
    public var useEventPass = false
    public var options: [Option] = []
    public var rangeStartDate: Date
    public var rangeEndDate: Date
    public var rangeStartTime: Date
    public var rangeEndTime: Date
    /// The days tapped on the all-day calendar. While `isAllDay` is on, these are the poll's options.
    public var selectedDates = Set<DateComponents>()
    public private(set) var formError: String?

    private let editor: PollCreationEditor
    private let auth: any AuthServiceProtocol
    private let polls: any PollServiceProtocol
    private let clock: AppClock
    private let currentCalendar: () -> Calendar

    /// `calendar` is read on each use, so a zone change on the device applies to the next action.
    public init(
        auth: any AuthServiceProtocol, polls: any PollServiceProtocol, clock: AppClock,
        calendar: @escaping () -> Calendar = { .current }, editor: PollCreationEditor = PollCreationEditor()
    ) {
        self.auth = auth
        self.polls = polls
        self.clock = clock
        currentCalendar = calendar
        self.editor = editor
        let initial = Self.defaultOption(at: clock.now, in: calendar())
        rangeStartDate = initial.date
        rangeEndDate = initial.date
        rangeStartTime = initial.startTime
        rangeEndTime = initial.endTime
    }

    // MARK: - Derived state

    /// The account whose draft the form should show.
    public var currentAccountId: UUID? { auth.currentUserId }
    public var now: Date { clock.now }
    public var calendar: Calendar { currentCalendar() }
    public var startOfToday: Date { currentCalendar().startOfDay(for: clock.now) }
    public var isSubmitting: Bool { editor.isSubmitting }
    /// An earlier submission's outcome is unknown, so only that exact submission may be retried.
    public var mustResolvePending: Bool { editor.mustResolvePending }
    /// Field edits wait while a submission runs or an unknown outcome is unresolved.
    public var isFormLocked: Bool { isSubmitting || mustResolvePending }
    public var canSubmit: Bool { !title.isEmpty && !isSubmitting }
    public var errorMessage: String? { formError ?? editor.errorMessage }

    // MARK: - Account

    /// Shows the signed-in account's retained draft, or an empty form when it has none.
    public func selectCurrentAccount() {
        editor.selectAccount(auth.currentUserId)
        restoreDraft(editor.pending?.payload)
    }

    // MARK: - Options

    public func addOption() {
        options.append(newOption())
    }

    /// Removes the option unless it is the last one.
    public func removeOption(id: Option.ID) {
        guard options.count > 1 else { return }
        options.removeAll { $0.id == id }
    }

    /// Adds one option per day in the range, each with the range's wall times.
    public func addDateRange() {
        let calendar = currentCalendar()
        let startDay = calendar.startOfDay(for: rangeStartDate)
        let endDay = calendar.startOfDay(for: rangeEndDate)

        guard startDay <= endDay else {
            formError = "Start date must be before or equal to end date"
            return
        }

        if !isAllDay {
            let startComponents = calendar.dateComponents([.hour, .minute], from: rangeStartTime)
            let endComponents = calendar.dateComponents([.hour, .minute], from: rangeEndTime)
            let startMinutes = (startComponents.hour ?? 0) * 60 + (startComponents.minute ?? 0)
            let endMinutes = (endComponents.hour ?? 0) * 60 + (endComponents.minute ?? 0)

            if endMinutes <= startMinutes {
                formError = "End time must be after start time"
                return
            }
        }

        var currentDate = startDay
        while currentDate <= endDay {
            options.append(Option(date: currentDate, startTime: rangeStartTime, endTime: rangeEndTime))
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        sortOptions()
        resetRangeFields()
        formError = nil
    }

    // MARK: - Submission

    /// Submits the form, or retries the unresolved submission unchanged, then calls
    /// `onCreated` once the poll exists.
    @discardableResult
    public func create(onCreated: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        formError = nil
        if isAllDay && selectedDates.isEmpty && !editor.mustResolvePending {
            formError = "Select at least one day."
            return nil
        }
        let payload: PollCreationPayload?
        if editor.mustResolvePending {
            payload = editor.pending?.payload
        } else {
            do {
                payload = try makePayload()
            } catch {
                formError = error.localizedDescription
                return nil
            }
        }
        guard let payload else { return nil }
        return auth.performSessionTask(
            operation: { _ in await self.editor.submit(payload, using: self.polls) },
            onSuccess: { _ in if self.editor.result != nil { onCreated() } }
        )
    }

    // MARK: - Private

    /// Today, from 09:00 to 10:00.
    private static func defaultOption(at now: Date, in calendar: Calendar) -> Option {
        Option(
            date: now,
            startTime: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now,
            endTime: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now) ?? now)
    }

    private func newOption() -> Option {
        Self.defaultOption(at: clock.now, in: currentCalendar())
    }

    private func sortOptions() {
        let calendar = currentCalendar()
        options.sort { option1, option2 in
            let date1 = calendar.startOfDay(for: option1.date)
            let date2 = calendar.startOfDay(for: option2.date)
            if date1 != date2 {
                return date1 < date2
            }
            return option1.startTime < option2.startTime
        }
    }

    private func resetRangeFields() {
        let defaults = newOption()
        rangeStartDate = defaults.date
        rangeEndDate = defaults.date
        rangeStartTime = defaults.startTime
        rangeEndTime = defaults.endTime
    }

    private func makePayload() throws(CalendarTimeError) -> PollCreationPayload {
        let zone = currentCalendar().timeZone
        return PollCreationPayload(
            title: title, description: description.isEmpty ? nil : description,
            location: location.isEmpty ? nil : location, timezone: zone.identifier,
            closesAt: hasDueDate ? CalendarDay(dueDate ?? clock.now, in: zone).deadline(in: zone) : nil,
            timeOptions: try makeOptions(in: zone),
            useEventPass: useEventPass
        )
    }

    /// Each option's picked date and wall times, resolved in `zone`.
    private func makeOptions(in zone: TimeZone) throws(CalendarTimeError) -> [PollCreationOption] {
        let calendar = currentCalendar()
        if isAllDay {
            return selectedDates.compactMap { calendar.date(from: $0) }.sorted()
                .map { .allDay(on: CalendarDay($0, in: calendar.timeZone), in: zone) }
        }
        return try options.map { option throws(CalendarTimeError) in
            let day = CalendarDay(option.date, in: calendar.timeZone)
            let start = calendar.dateComponents([.hour, .minute], from: option.startTime)
            let end = calendar.dateComponents([.hour, .minute], from: option.endTime)
            return try .timed(
                on: day, start: (start.hour ?? 9, start.minute ?? 0), end: (end.hour ?? 10, end.minute ?? 0), in: zone)
        }
    }

    private func restoreDraft(_ payload: PollCreationPayload?) {
        let calendar = currentCalendar()
        title = payload?.title ?? ""
        description = payload?.description ?? ""
        location = payload?.location ?? ""
        // A stored deadline is the start of the day after the due date.
        let zone = payload.flatMap { TimeZone(identifier: $0.timezone) } ?? calendar.timeZone
        dueDate = payload?.closesAt.map { CalendarDay.dueDate(for: $0, in: zone).pickerDate(calendar: calendar) }
        hasDueDate = dueDate != nil
        useEventPass = payload?.useEventPass ?? false
        isAllDay = payload?.timeOptions.first?.isAllDay ?? false
        options = payload?.timeOptions.map {
            Option(
                date: $0.isAllDay ? CalendarDay($0.startTime, in: zone).pickerDate(calendar: calendar) : $0.startTime,
                startTime: $0.startTime, endTime: $0.endTime)
        } ?? []
        selectedDates = isAllDay
            ? Set(options.map { calendar.dateComponents([.calendar, .era, .year, .month, .day], from: $0.date) })
            : []
        formError = nil
    }
}
