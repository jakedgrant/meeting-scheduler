import Foundation

/// The detail screen edits a draft; only command results become saved state.
@MainActor
@Observable
public final class AvailabilityEditor {
    public var responses: [UUID: AvailabilityStatus] = [:] { didSet { retainDraft() } }
    public var comment = "" { didSet { retainDraft() } }
    public private(set) var saved: AvailabilitySnapshot?
    public private(set) var isSaving = false
    public private(set) var isLoading = false
    public private(set) var needsConflictReview = false
    public private(set) var isClosed = false
    public private(set) var errorMessage: String?
    public private(set) var didSave = false
    private var notes: [UUID: String] = [:]
    private var generation: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var pending: SaveAvailabilityRequest?

    private struct Recovery {
        let responses: [UUID: AvailabilityStatus]
        let comment: String
        let notes: [UUID: String]
        let saved: AvailabilitySnapshot?
        let pending: SaveAvailabilityRequest?
        let needsConflictReview: Bool
    }
    private static var recovery: [UUID: [UUID: Recovery]] = [:]
    private var accountId: UUID?
    private var pollId: UUID?
    private var restoring = false
    private var recoveredDraft = false

    public init() {}

    /// Account-scoped in-process recovery survives screen recreation and logout.
    /// Creation's separate durable envelope remains unchanged.
    public func selectAccount(_ accountId: UUID?, pollId: UUID) {
        retainDraft()
        restoring = true
        self.accountId = nil; self.pollId = nil
        reset()
        self.accountId = accountId; self.pollId = pollId
        if let accountId, let value = Self.recovery[accountId]?[pollId] {
            responses = value.responses; comment = value.comment; notes = value.notes
            saved = value.saved; pending = value.pending; needsConflictReview = value.needsConflictReview
            recoveredDraft = true
        }
        restoring = false
    }

    /// Retain retry identity, then fence suspended work when its screen leaves.
    public func suspend() {
        retainDraft()
        restoring = true
        accountId = nil; pollId = nil
        reset()
        restoring = false
    }

    private func retainDraft() {
        guard !restoring, let accountId, let pollId else { return }
        Self.recovery[accountId, default: [:]][pollId] = Recovery(responses: responses, comment: comment,
            notes: notes, saved: saved, pending: pending, needsConflictReview: needsConflictReview)
    }

    public func reset() {
        recoveredDraft = false
        generation &+= 1
        loadGeneration &+= 1
        responses = [:]; comment = ""; notes = [:]; saved = nil; pending = nil
        isSaving = false; isLoading = false; needsConflictReview = false
        isClosed = false; errorMessage = nil; didSave = false
    }

    private var answers: [AvailabilityAnswer] {
        responses.keys.sorted { $0.uuidString < $1.uuidString }.map {
            AvailabilityAnswer(timeOptionId: $0, status: responses[$0]!, note: notes[$0])
        }
    }
    private var trimmedComment: String? {
        let value = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    public var isSaved: Bool {
        guard let saved else { return false }
        let persisted = saved.responses.map { AvailabilityAnswer(timeOptionId: $0.timeOptionId, status: $0.status, note: $0.note) }
            .sorted { $0.timeOptionId.uuidString < $1.timeOptionId.uuidString }
        return pending == nil && answers == persisted && trimmedComment == saved.comment
    }

    public func load(pollId: UUID, participantId: UUID, guestToken: String? = nil,
                     preservingDraft: Bool = false, using service: any PollServiceProtocol) async {
        // An ambiguous command must retry its original version and UUID. A read
        // here would discard that envelope after a lost successful reply.
        if recoveredDraft, pending != nil { recoveredDraft = false; return }
        let identity = generation
        let retainKnownDraft = (preservingDraft || recoveredDraft) && saved != nil
        recoveredDraft = false
        loadGeneration &+= 1
        let request = loadGeneration
        isLoading = true
        defer { if generation == identity && request == loadGeneration { isLoading = false } }
        do {
            let snapshot = try await service.getAvailability(pollId: pollId, participantId: participantId, guestToken: guestToken)
            guard generation == identity, request == loadGeneration, !Task.isCancelled else { return }
            guard snapshot.pollId == pollId, snapshot.participantId == participantId else { throw AvailabilityCommandError.invalidRequest }
            saved = snapshot
            pending = nil
            needsConflictReview = false
            errorMessage = nil
            if !retainKnownDraft { adoptDraft(snapshot) }
            retainDraft()
        } catch {
            guard generation == identity, request == loadGeneration, !Task.isCancelled else { return }
            errorMessage = "Saved responses could not be loaded. Your draft has been retained. Retry loading before saving."
        }
    }

    public func save(pollId: UUID, participantId: UUID, guestToken: String? = nil, using service: any PollServiceProtocol) async {
        guard !isSaving, !isLoading, !needsConflictReview, !isClosed else { return }
        guard let saved else {
            errorMessage = "Load saved responses before saving. Your draft has been retained."
            return
        }
        guard comment.count <= 500 else { errorMessage = "Comment must be 500 characters or fewer."; return }
        let draft = answers
        let draftComment = trimmedComment
        if pending?.responses != draft || pending?.comment != draftComment {
            pending = SaveAvailabilityRequest(pollId: pollId, responses: draft, comment: draftComment,
                                              expectedVersion: saved.version, participantId: participantId, guestToken: guestToken)
        }
        retainDraft()
        guard let operation = pending else { return }
        let identity = generation
        isSaving = true; didSave = false; errorMessage = nil
        defer { if generation == identity { isSaving = false } }
        do {
            let snapshot = try await service.saveAvailability(operation)
            guard generation == identity, !Task.isCancelled else { return }
            guard snapshot.pollId == pollId, snapshot.participantId == participantId else { throw AvailabilityCommandError.invalidRequest }
            self.saved = snapshot
            pending = nil
            didSave = true
            // An edit made while suspended remains a draft even though the submitted operation succeeded.
            if answers == draft && trimmedComment == draftComment { adoptDraft(snapshot) }
            retainDraft()
        } catch {
            guard generation == identity, !Task.isCancelled else { return }
            let failure = (error as? AvailabilityCommandError) ?? .transport
            errorMessage = failure.localizedDescription
            if failure == .conflict { needsConflictReview = true; pending = nil }
            if failure == .closed { isClosed = true }
            retainDraft()
        }
    }

    private func adoptDraft(_ snapshot: AvailabilitySnapshot) {
        responses = Dictionary(uniqueKeysWithValues: snapshot.responses.map { ($0.timeOptionId, $0.status) })
        notes = Dictionary(uniqueKeysWithValues: snapshot.responses.compactMap { value in value.note.map { (value.timeOptionId, $0) } })
        comment = snapshot.comment ?? ""
    }
}
