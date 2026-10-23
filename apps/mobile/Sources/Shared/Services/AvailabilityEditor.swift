import Foundation

/// The detail screen edits a draft; only command results become saved state.
@MainActor
@Observable
public final class AvailabilityEditor {
    public var responses: [UUID: AvailabilityStatus] = [:]
    public var comment = ""
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

    public init() {}

    public func reset() {
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
        let identity = generation
        let retainKnownDraft = preservingDraft && saved != nil
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
        } catch {
            guard generation == identity, !Task.isCancelled else { return }
            let failure = (error as? AvailabilityCommandError) ?? .transport
            errorMessage = failure.localizedDescription
            if failure == .conflict { needsConflictReview = true; pending = nil }
            if failure == .closed { isClosed = true }
        }
    }

    private func adoptDraft(_ snapshot: AvailabilitySnapshot) {
        responses = Dictionary(uniqueKeysWithValues: snapshot.responses.map { ($0.timeOptionId, $0.status) })
        notes = Dictionary(uniqueKeysWithValues: snapshot.responses.compactMap { value in value.note.map { (value.timeOptionId, $0) } })
        comment = snapshot.comment ?? ""
    }
}
