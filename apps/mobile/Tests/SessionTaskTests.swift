import XCTest
@testable import Shared

@MainActor
private final class SessionTaskGate {
    private var continuation: CheckedContinuation<Int, any Error>?

    func read() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitForStart(file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2000 {
            if continuation != nil { return }
            await Task.yield()
        }
        XCTFail("Screen operation did not start", file: file, line: line)
    }

    func finish(failing: Bool = false) {
        let pending = continuation
        continuation = nil
        if failing { pending?.resume(throwing: SessionTaskFailure.expected) }
        else { pending?.resume(returning: 42) }
    }
}

private enum SessionTaskFailure: Error { case expected }

@MainActor
final class SessionTaskTests: XCTestCase {
    func testCurrentSuccessAndFailurePublishAndFinishExactlyOnce() async {
        let auth = MockAuthService.signedIn
        for failing in [false, true] {
            var events: [String] = []
            let task = auth.performSessionTask(
                operation: { _ in
                    events.append("operation")
                    if failing { throw SessionTaskFailure.expected }
                    return 42
                },
                onSuccess: { events.append("success:\($0)") },
                onFailure: { _ in events.append("failure") },
                onCompletion: { events.append("completion") }
            )
            await task.value
            XCTAssertEqual(events, ["operation", failing ? "failure" : "success:42", "completion"])
        }
    }

    func testOwnershipIsCapturedBeforeTaskScheduling() async {
        for change in 0..<3 {
            let auth = MockAuthService.signedIn
            var screenIsCurrent = true
            var calls = 0
            let task = auth.performSessionTask(
                operation: { _ in calls += 1 },
                onSuccess: { _ in calls += 1 },
                onFailure: { _ in calls += 1 },
                onCompletion: { calls += 1 },
                isCurrent: { screenIsCurrent }
            )
            switch change {
            case 0: auth.sessionGeneration += 1 // Even the same UUID is a new session.
            case 1: auth.currentUserId = UUID() // Fail closed on inconsistent identity/generation.
            default: screenIsCurrent = false
            }
            await task.value
            XCTAssertEqual(calls, 0)
        }
    }

    func testDelayedSuccessFailureAndCleanupCannotReachReplacementSessions() async {
        for returningToA in [false, true] {
            for throughLogout in [false, true] {
                for failing in [false, true] {
                    let auth = MockAuthService.signedIn
                    let accountA = auth.currentUserId
                    let gate = SessionTaskGate()
                    var publications = 0
                    let task = auth.performSessionTask(
                        operation: { _ in try await gate.read() },
                        onSuccess: { _ in publications += 1 },
                        onFailure: { _ in publications += 1 },
                        onCompletion: { publications += 1 }
                    )
                    await gate.waitForStart()
                    auth.currentUserId = throughLogout ? nil : UUID()
                    auth.sessionGeneration += 1
                    if returningToA {
                        auth.currentUserId = accountA
                        auth.sessionGeneration += 1
                    }
                    gate.finish(failing: failing)
                    await task.value
                    XCTAssertEqual(publications, 0)
                }
            }
        }
    }

    func testSameSessionRefreshAndProfileUpdatesKeepPendingWorkCurrent() async {
        let auth = MockAuthService.signedIn
        let gate = SessionTaskGate()
        var result: Int?
        var completions = 0
        let task = auth.performSessionTask(
            operation: { _ in try await gate.read() },
            onSuccess: { result = $0 },
            onCompletion: { completions += 1 }
        )
        await gate.waitForStart()
        // AuthService keeps the account/generation stable on ordinary refresh.
        auth.currentUserEmail = "updated@example.invalid"
        auth.profile = nil
        gate.finish()
        await task.value
        XCTAssertEqual(result, 42)
        XCTAssertEqual(completions, 1)
    }

    func testCancellationBeforeStartSkipsDispatchAndFinishesCurrentLoading() async {
        let auth = MockAuthService.signedIn
        var dispatched = false
        var isLoading = true
        let task = auth.performSessionTask(
            operation: { _ in dispatched = true },
            onCompletion: { isLoading = false }
        )
        task.cancel()
        await task.value
        XCTAssertFalse(dispatched)
        XCTAssertFalse(isLoading)
    }

    func testCancellationSuppressesUncooperativeSuccessAndFailureButFinishesCurrentScreen() async {
        for failing in [false, true] {
            let auth = MockAuthService.signedIn
            let gate = SessionTaskGate()
            var publications = 0
            var completions = 0
            let task = auth.performSessionTask(
                operation: { _ in try await gate.read() },
                onSuccess: { _ in publications += 1 },
                onFailure: { _ in publications += 1 },
                onCompletion: { completions += 1 }
            )
            await gate.waitForStart()
            task.cancel()
            gate.finish(failing: failing)
            await task.value
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(completions, 1)
        }
    }

    func testCancellationErrorIsSilentAndFinishesCurrentScreen() async {
        let auth = MockAuthService.signedIn
        var errors = 0
        var completions = 0
        let task = auth.performSessionTask(
            operation: { _ in throw CancellationError() },
            onFailure: { _ in errors += 1 },
            onCompletion: { completions += 1 }
        )
        await task.value
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(completions, 1)
    }

    func testRecreatedScreenKeepsNewLoadingStateWhenOldWorkFinishes() async {
        for failing in [false, true] {
            let auth = MockAuthService.signedIn
            let oldGate = SessionTaskGate()
            let currentGate = SessionTaskGate()
            var screenGeneration = 1
            var isLoading = true
            var publications = 0
            let oldTask = auth.performSessionTask(
                operation: { _ in try await oldGate.read() },
                onSuccess: { _ in publications += 1 },
                onFailure: { _ in publications += 1 },
                onCompletion: { isLoading = false },
                isCurrent: { screenGeneration == 1 }
            )
            await oldGate.waitForStart()
            screenGeneration = 2
            let currentTask = auth.performSessionTask(
                operation: { _ in try await currentGate.read() },
                onSuccess: { _ in publications += 1 },
                onCompletion: { isLoading = false },
                isCurrent: { screenGeneration == 2 }
            )
            await currentGate.waitForStart()
            oldGate.finish(failing: failing)
            await oldTask.value
            XCTAssertTrue(isLoading)
            XCTAssertEqual(publications, 0)
            currentGate.finish()
            await currentTask.value
            XCTAssertFalse(isLoading)
            XCTAssertEqual(publications, 1)
        }
    }

    func testCallbacksThatReplaceSessionCannotCleanUpReplacementState() async {
        for failing in [false, true] {
            let auth = MockAuthService.signedIn
            var isLoading = true
            let replaceSession: @MainActor () -> Void = { auth.sessionGeneration += 1 }
            let task = auth.performSessionTask(
                operation: { _ in
                    if failing { throw SessionTaskFailure.expected }
                },
                onSuccess: { _ in replaceSession() },
                onFailure: { _ in replaceSession() },
                onCompletion: { isLoading = false }
            )
            await task.value
            XCTAssertTrue(isLoading)
        }
    }

    func testMultiStageOperationChecksOwnershipBeforeDispatchingNextStage() async {
        for replaceScreen in [false, true] {
            let auth = MockAuthService.signedIn
            let gate = SessionTaskGate()
            var screenIsCurrent = true
            var secondStageCalls = 0
            var publications = 0
            let task = auth.performSessionTask(
                operation: { scope in
                    _ = try await gate.read()
                    try scope.checkCancellation()
                    secondStageCalls += 1
                },
                onSuccess: { _ in publications += 1 },
                onFailure: { _ in publications += 1 },
                onCompletion: { publications += 1 },
                isCurrent: { screenIsCurrent }
            )
            await gate.waitForStart()
            if replaceScreen { screenIsCurrent = false }
            else { auth.sessionGeneration += 1 }
            gate.finish()
            await task.value
            XCTAssertEqual(secondStageCalls, 0)
            XCTAssertEqual(publications, 0)
        }
    }
}
