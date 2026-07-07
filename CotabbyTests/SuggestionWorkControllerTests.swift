import XCTest
@testable import Cotabby

/// Tests the supersede-don't-abort semantics that let a decode finish for salvage while the newest
/// request queues behind it — the mechanism behind suggestions appearing while the user types.
/// (The base latest-request-wins semantics are covered in `SuggestionStateHelperTests`.)
@MainActor
final class SuggestionWorkControllerPreservationTests: XCTestCase {
    /// An operation that stays "running" until the test explicitly finishes it, standing in for a
    /// llama decode in flight.
    private final class Gate: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            var continuation: AsyncStream<Void>.Continuation!
            stream = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }

        func open() { continuation.finish() }
        func wait() async { for await _ in stream {} }
    }

    private func drainMainQueue() async {
        // Give the controller's tasks a few main-actor turns to observe gate state changes.
        for _ in 0..<20 { await Task.yield() }
    }

    func test_preservingReplaceLetsRunningGenerationFinish() async {
        let controller = SuggestionWorkController()
        let gate = Gate()
        var generationCompleted = false
        var sawCancellation = false

        let workID = controller.replaceDebouncedWork(delayMilliseconds: 0) { _ in }
        controller.replaceGenerationWork(for: workID) {
            await gate.wait()
            sawCancellation = Task.isCancelled
            generationCompleted = true
        }
        await drainMainQueue()

        // A newer keystroke supersedes but preserves: the running generation must not be cancelled.
        controller.replaceDebouncedWork(delayMilliseconds: 0, preservingInFlightGeneration: true) { _ in }
        gate.open()
        await drainMainQueue()

        XCTAssertTrue(generationCompleted, "The preserved decode ran to completion")
        XCTAssertFalse(sawCancellation, "Preservation means no cooperative cancellation fired")
        XCTAssertFalse(controller.isCurrent(workID), "The old work id is stale, so its result salvages")
    }

    func test_nonPreservingReplaceCancelsRunningGeneration() async {
        let controller = SuggestionWorkController()
        let gate = Gate()
        var sawCancellation = false

        let workID = controller.replaceDebouncedWork(delayMilliseconds: 0) { _ in }
        controller.replaceGenerationWork(for: workID) {
            await gate.wait()
            sawCancellation = Task.isCancelled
        }
        await drainMainQueue()

        controller.replaceDebouncedWork(delayMilliseconds: 0) { _ in }
        gate.open()
        await drainMainQueue()

        XCTAssertTrue(sawCancellation, "The default replace hard-cancels the in-flight decode")
    }

    func test_requestArrivingMidDecodeQueuesAndStartsAfterwardLatestWins() async {
        let controller = SuggestionWorkController()
        let gate = Gate()
        var startedOperations: [String] = []

        let firstID = controller.replaceDebouncedWork(delayMilliseconds: 0) { _ in }
        controller.replaceGenerationWork(for: firstID) {
            startedOperations.append("first")
            await gate.wait()
        }
        await drainMainQueue()

        // Two newer requests arrive while the first is decoding; only the newest may run after it.
        let secondID = controller.replaceDebouncedWork(
            delayMilliseconds: 0, preservingInFlightGeneration: true
        ) { _ in }
        controller.replaceGenerationWork(for: secondID) { startedOperations.append("second") }
        let thirdID = controller.replaceDebouncedWork(
            delayMilliseconds: 0, preservingInFlightGeneration: true
        ) { _ in }
        controller.replaceGenerationWork(for: thirdID) { startedOperations.append("third") }

        gate.open()
        await drainMainQueue()

        XCTAssertEqual(startedOperations, ["first", "third"], "Depth-one queue, latest wins")
    }

    func test_cancelAllDropsTheQueuedGeneration() async {
        let controller = SuggestionWorkController()
        let gate = Gate()
        var queuedRan = false

        let firstID = controller.replaceDebouncedWork(delayMilliseconds: 0) { _ in }
        controller.replaceGenerationWork(for: firstID) { await gate.wait() }
        await drainMainQueue()

        let secondID = controller.replaceDebouncedWork(
            delayMilliseconds: 0, preservingInFlightGeneration: true
        ) { _ in }
        controller.replaceGenerationWork(for: secondID) { queuedRan = true }

        controller.cancelAll()
        gate.open()
        await drainMainQueue()

        XCTAssertFalse(queuedRan, "A hard cancel clears the queued request too")
    }
}
