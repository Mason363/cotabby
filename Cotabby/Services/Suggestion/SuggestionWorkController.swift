import Foundation

/// File overview:
/// Owns the debounce task, in-flight generation task, and monotonically increasing work id for
/// the suggestion pipeline. `SuggestionCoordinator` decides *when* work should happen; this type
/// owns *how* asynchronous work is replaced, cancelled, and identified as stale.
///
/// That split mirrors a common React pattern: a container owns intent, while a smaller helper owns
/// request lifecycle bookkeeping so stale async completions cannot write old state back into the UI.
///
/// The one behavior that makes suggestions appear *while the user types* lives here: an insertion
/// keystroke supersedes the in-flight decode (its work id goes stale) but does NOT abort it. Aborting
/// on every keystroke meant continuous typing never let any generation finish, so ghost text only
/// ever appeared after the user stopped. A superseded-but-finished decode is salvage fodder — if the
/// user typed exactly the characters it predicted, its tail is still the right suggestion — so the
/// decode is allowed to complete and the *newest* request queues behind it (depth one, latest wins)
/// instead of stacking. Destructive events (deletion, navigation, focus change) still hard-cancel.
@MainActor
final class SuggestionWorkController {
    private var debounceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var latestWorkID: UInt64 = 0

    /// True while a generation task is actually executing its operation. Drives the depth-one queue
    /// below: a new request arriving mid-decode waits for the running one instead of aborting it.
    private var isGenerationRunning = false
    /// The newest generation request that arrived while one was still running. Overwritten by every
    /// newer arrival (latest wins) and started — if still current — when the runner finishes.
    private var pendingGeneration: (workID: UInt64, operation: @MainActor () async -> Void)?
    /// Identity of the current generation run. `finishGeneration` is a completion callback from the
    /// task itself; the token stops a cancelled old task's late completion from clearing the running
    /// flag (or starting the queued request) out from under a newer run.
    private var generationRunToken: UInt64 = 0

    var currentWorkID: UInt64 {
        latestWorkID
    }

    /// Replaces pending work with one fresh debounced operation. The returned work id becomes the
    /// only valid id for future result application.
    ///
    /// `preservingInFlightGeneration` selects the supersede-don't-abort behavior described in the
    /// file overview: the debounce is always replaced, but a running decode is left to finish so its
    /// result can be salvaged. `false` (the default) keeps the historical hard-cancel for callers
    /// whose triggering event invalidates the in-flight prefix (deletion, dismissal, focus change).
    @discardableResult
    func replaceDebouncedWork(
        delayMilliseconds: Int,
        preservingInFlightGeneration: Bool = false,
        operation: @escaping @MainActor (UInt64) async -> Void
    ) -> UInt64 {
        if preservingInFlightGeneration {
            debounceTask?.cancel()
            debounceTask = nil
        } else {
            cancelTasks()
        }
        latestWorkID &+= 1
        let workID = latestWorkID

        debounceTask = Task { [weak self] in
            let delayNanoseconds = UInt64(delayMilliseconds) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            guard let self, !Task.isCancelled, workID == self.latestWorkID else {
                return
            }

            await operation(workID)
        }

        return workID
    }

    /// Starts one generation task for the current work id, or — when a preserved decode is still
    /// running — queues it (depth one, latest wins) to start the moment the runner finishes. The
    /// controller guards against late starts so the coordinator does not need to keep repeating the
    /// same stale-work checks.
    func replaceGenerationWork(
        for workID: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard !isGenerationRunning else {
            pendingGeneration = (workID, operation)
            return
        }
        startGenerationTask(workID: workID, operation: operation)
    }

    private func startGenerationTask(
        workID: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        generationTask?.cancel()
        generationRunToken &+= 1
        let runToken = generationRunToken
        isGenerationRunning = true
        generationTask = Task { [weak self] in
            guard let self else { return }
            if !Task.isCancelled, workID == self.latestWorkID {
                await operation()
            }
            self.finishGeneration(runToken: runToken)
        }
    }

    /// Completion callback from the generation task: clears the running flag and starts the queued
    /// request if it is still the newest work. The token guard means only the *current* run's
    /// completion can do this — a cancelled predecessor resuming late is ignored.
    private func finishGeneration(runToken: UInt64) {
        guard runToken == generationRunToken else { return }
        isGenerationRunning = false
        guard let pending = pendingGeneration else { return }
        pendingGeneration = nil
        guard pending.workID == latestWorkID else { return }
        startGenerationTask(workID: pending.workID, operation: pending.operation)
    }

    /// Cancels all in-flight work and advances the work id so any late completions are rejected.
    func cancelAll() {
        cancelTasks()
        latestWorkID &+= 1
    }

    func isCurrent(_ workID: UInt64) -> Bool {
        workID == latestWorkID
    }

    private func cancelTasks() {
        debounceTask?.cancel()
        generationTask?.cancel()
        debounceTask = nil
        generationTask = nil
        pendingGeneration = nil
        // Invalidate the run token so the cancelled task's late completion callback is a no-op
        // instead of clearing state that a subsequently started run now owns.
        generationRunToken &+= 1
        isGenerationRunning = false
    }
}
