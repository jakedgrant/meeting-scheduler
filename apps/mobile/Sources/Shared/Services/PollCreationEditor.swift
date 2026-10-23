import Foundation

@MainActor
public protocol PollCreationDraftStore {
    func read(accountId: UUID) throws -> Data?
    func write(_ data: Data?, accountId: UUID) throws
}

@MainActor
public final class FilePollCreationDraftStore: PollCreationDraftStore {
    private let directory: URL
    public init(directory: URL = URL.applicationSupportDirectory.appending(path: "PollCreationDrafts", directoryHint: .isDirectory)) {
        self.directory = directory
    }
    private func file(_ accountId: UUID) -> URL { directory.appending(path: "\(accountId.uuidString.lowercased()).json") }
    public func read(accountId: UUID) throws -> Data? {
        let url = file(accountId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    public func write(_ data: Data?, accountId: UUID) throws {
        let url = file(accountId)
        if let data {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Retains the exact submitted envelope before dispatch, scoped to its account.
/// An uncertain reply freezes the envelope until replay resolves its result.
@MainActor
@Observable
public final class PollCreationEditor {
    public private(set) var pending: CreatePollRequest?
    public private(set) var mustResolvePending = false
    public private(set) var isSubmitting = false
    public private(set) var errorMessage: String?
    public private(set) var result: PollCreationResult?
    private var accountId: UUID?
    private var canReadDraft = true
    private var generation: UInt64 = 0
    private let store: any PollCreationDraftStore
    private struct Envelope: Codable { let request: CreatePollRequest; let unresolved: Bool }

    public init(store: any PollCreationDraftStore = FilePollCreationDraftStore()) { self.store = store }

    public func selectAccount(_ id: UUID?) {
        guard accountId != id else { return }
        generation &+= 1
        accountId = id
        canReadDraft = true
        pending = nil; mustResolvePending = false; isSubmitting = false; result = nil; errorMessage = nil
        guard let id else { return }
        do {
            if let data = try store.read(accountId: id) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: data)
                pending = envelope.request; mustResolvePending = envelope.unresolved
                if mustResolvePending { errorMessage = PollCreationError.transport.localizedDescription }
            }
        } catch { canReadDraft = false; errorMessage = PollCreationError.draftStorage.localizedDescription }
    }

    private func persist(account: UUID, unresolved: Bool) throws {
        let data = try pending.map { try JSONEncoder().encode(Envelope(request: $0, unresolved: unresolved)) }
        try store.write(data, accountId: account)
    }

    public func submit(_ payload: PollCreationPayload, using service: any PollServiceProtocol) async {
        guard !isSubmitting else { return }
        guard canReadDraft else { errorMessage = PollCreationError.draftStorage.localizedDescription; return }
        guard let accountId else { errorMessage = PollCreationError.authentication.localizedDescription; return }
        // Never create a second poll to resolve an uncertain first request.
        if mustResolvePending && pending?.payload != payload {
            errorMessage = PollCreationError.transport.localizedDescription; return
        }
        guard !payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.timeOptions.isEmpty,
              payload.timeOptions.allSatisfy({ $0.endTime > $0.startTime }) else {
            errorMessage = "Enter a title and valid time options. Every end time must be after its start."
            return
        }
        if pending?.payload != payload { pending = CreatePollRequest(payload: payload) }
        guard let request = pending else { return }
        // Persist as unresolved before network dispatch, including a process crash or lost reply.
        do { try persist(account: accountId, unresolved: true) }
        catch { errorMessage = PollCreationError.draftStorage.localizedDescription; return }
        mustResolvePending = true
        let identity = generation
        isSubmitting = true; result = nil; errorMessage = nil
        defer { if generation == identity { isSubmitting = false } }
        do {
            let saved = try await service.createPoll(request)
            guard generation == identity, !Task.isCancelled else { return }
            guard saved.poll.creatorId == accountId,
                  saved.timeOptions.allSatisfy({ $0.pollId == saved.poll.id }) else { throw PollCreationError.transport }
            result = saved
            pending = nil; mustResolvePending = false
            // A failed local removal is safe: replaying the stored operation returns this same poll.
            try? persist(account: accountId, unresolved: false)
        } catch {
            guard generation == identity, !Task.isCancelled else { return }
            let failure = error as? PollCreationError ?? .transport
            mustResolvePending = failure == .transport || failure == .changedOperation
            errorMessage = failure.localizedDescription
            try? persist(account: accountId, unresolved: mustResolvePending)
        }
    }
}
