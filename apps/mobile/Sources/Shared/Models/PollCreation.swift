import Foundation

private func creationInstant(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    if let date = formatter.date(from: value) { return date }
    throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Creation date must be an ISO 8601 instant"))
}

public struct PollCreationOption: Codable, Equatable, Sendable {
    public let startTime: Date
    public let endTime: Date
    public let isAllDay: Bool
    enum CodingKeys: String, CodingKey { case startTime = "start_time", endTime = "end_time", isAllDay = "is_all_day" }
    public init(startTime: Date, endTime: Date, isAllDay: Bool) {
        self.startTime = Date(timeIntervalSince1970: startTime.timeIntervalSince1970.rounded(.down))
        self.endTime = Date(timeIntervalSince1970: endTime.timeIntervalSince1970.rounded(.down))
        self.isAllDay = isAllDay
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        startTime = try creationInstant(values.decode(String.self, forKey: .startTime))
        endTime = try creationInstant(values.decode(String.self, forKey: .endTime))
        isAllDay = try values.decode(Bool.self, forKey: .isAllDay)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // Explicit UTC suffix; the SDK's default Date encoder omits its zone.
        try values.encode(startTime.ISO8601Format(), forKey: .startTime)
        try values.encode(endTime.ISO8601Format(), forKey: .endTime)
        try values.encode(isAllDay, forKey: .isAllDay)
    }

}

public struct PollCreationPayload: Codable, Equatable, Sendable {
    public let title: String
    public let description: String?
    public let location: String?
    public let timezone: String
    public let closesAt: Date?
    public let timeOptions: [PollCreationOption]
    public let useEventPass: Bool
    enum CodingKeys: String, CodingKey {
        case title, description, location, timezone, closesAt = "closes_at", timeOptions = "time_options", useEventPass = "use_event_pass"
    }
    public init(title: String, description: String? = nil, location: String? = nil, timezone: String,
                closesAt: Date? = nil, timeOptions: [PollCreationOption], useEventPass: Bool = false) {
        self.title = title; self.description = description; self.location = location; self.timezone = timezone
        self.closesAt = closesAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        self.timeOptions = timeOptions; self.useEventPass = useEventPass
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        location = try values.decodeIfPresent(String.self, forKey: .location)
        timezone = try values.decode(String.self, forKey: .timezone)
        closesAt = try values.decodeIfPresent(String.self, forKey: .closesAt).map(creationInstant)
        timeOptions = try values.decode([PollCreationOption].self, forKey: .timeOptions)
        useEventPass = try values.decode(Bool.self, forKey: .useEventPass)
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encode(description, forKey: .description)
        try values.encode(location, forKey: .location)
        try values.encode(timezone, forKey: .timezone)
        try values.encode(closesAt?.ISO8601Format(), forKey: .closesAt)
        try values.encode(timeOptions, forKey: .timeOptions)
        try values.encode(useEventPass, forKey: .useEventPass)
    }
}

public struct CreatePollRequest: Codable, Sendable {
    public let operationId: UUID
    public let payload: PollCreationPayload
    enum CodingKeys: String, CodingKey { case operationId = "operation_id", payload }
    public init(operationId: UUID = UUID(), payload: PollCreationPayload) {
        self.operationId = operationId; self.payload = payload
    }
}

public enum PollCreationEntitlement: String, Codable, Sendable {
    case free, pro = "pro_access", team = "team_access", eventPass = "event_pass"
}

public struct PollCreationResult: Codable, Sendable {
    public let poll: Poll
    public let timeOptions: [PollTimeOption]
    public let redeemedPassId: UUID?
    public let entitlement: PollCreationEntitlement
    public let replayed: Bool
    enum CodingKeys: String, CodingKey {
        case poll, timeOptions = "time_options", redeemedPassId = "redeemed_pass_id", entitlement, replayed
    }
    public init(poll: Poll, timeOptions: [PollTimeOption], redeemedPassId: UUID? = nil,
                entitlement: PollCreationEntitlement = .free, replayed: Bool = false) {
        self.poll = poll; self.timeOptions = timeOptions; self.redeemedPassId = redeemedPassId
        self.entitlement = entitlement; self.replayed = replayed
    }
}

public enum PollCreationError: Error, LocalizedError, Equatable {
    case authentication, quota, passUnavailable, invalidPayload, changedOperation, shareCodeUnavailable, transport, draftStorage, draftUnreadable
    public var errorDescription: String? {
        switch self {
        case .authentication: "Sign in again before creating this poll. Your draft has been retained."
        case .quota: "Your active poll limit has been reached. Close an active poll or choose an available event pass, then retry. Your draft has been retained."
        case .passUnavailable: "An event pass could not be used. Check your purchases or turn off Use Event Pass, then retry. Your draft has been retained."
        case .invalidPayload: "This poll could not be created. Check its title, deadline and time options, then retry. Your draft has been retained."
        case .changedOperation: "This retry does not match the original creation. Your draft has been retained. Reopen the form to recover the original request."
        case .shareCodeUnavailable: "A share code could not be allocated. Retry this creation. Your draft has been retained."
        case .transport: "Creation could not be confirmed. Retry to recover or finish the same poll. Your submitted draft is retained and locked until this is resolved."
        case .draftUnreadable: "Your saved creation could not be read. Check My Polls, then reopen this form to retry loading your saved request before creating another poll."
        case .draftStorage: "Your draft could not be saved on this device. Free some storage and retry before creating the poll."
        }
    }
}
