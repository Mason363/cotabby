import Foundation

/// File overview:
/// The on-device memory of who the writer is: the weighted, persisted set of `UserMemoryFact`s that
/// `UserMemoryDistiller` learns from snapshots of the user's writing. `ingest` folds each batch of
/// distilled candidates in with weight accumulation, and `digest()` renders the confident subset
/// into the stable prompt line the request factory injects, so suggestions are conditioned on the
/// writer over time instead of starting cold in every field.
///
/// Privacy and cost posture:
/// - Everything stays in `UserDefaults` on this machine; nothing is uploaded, and learning runs on
///   the local model only while the user is idle (see the coordinator's distillation scheduling).
/// - The feature is opt-out (`isEnabled`, default on) and forgettable (`clear`, also reachable via
///   `clearNotification` so the menu can wipe memory without a direct reference to this store).
@MainActor
final class UserMemoryStore {
    /// Defaults key for the user's opt-out toggle. Absent means enabled, so the feature is on by
    /// default without a migration writing the key.
    static let enabledDefaultsKey = "cotabbyLearnedMemoryEnabled"
    /// Posted by the menu's "Forget what you've learned" control; a live store wipes itself on receipt.
    static let clearNotification = Notification.Name("cotabbyClearLearnedMemory")

    private static let factsDefaultsKey = "cotabbyLearnedMemoryFacts"
    /// Ceiling on any single fact's weight so an early, often-repeated fact cannot become permanent
    /// and drown out newer truth once the user's life changes.
    private static let maxWeight = 25
    /// Per-category cap so an adversarial or noisy field cannot grow the store without bound.
    private static let maxFactsPerCategory = 8

    private let userDefaults: UserDefaults
    private let now: () -> Date
    private(set) var facts: [UserMemoryFact]

    private var clearObserver: NSObjectProtocol?

    init(userDefaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.userDefaults = userDefaults
        self.now = now
        self.facts = Self.loadFacts(from: userDefaults)

        // The menu posts a notification rather than holding this store, so wiping memory needs no
        // path through the dependency graph. Delivering on the main queue keeps us on the actor.
        clearObserver = NotificationCenter.default.addObserver(
            forName: Self.clearNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    deinit {
        if let clearObserver {
            NotificationCenter.default.removeObserver(clearObserver)
        }
    }

    /// Whether the feature is on. Absent key = on (opt-out), matching the menu toggle's default.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) == nil ? true : defaults.bool(forKey: enabledDefaultsKey)
    }

    /// Folds a batch of distilled candidates into the persistent set with weight accumulation, then
    /// prunes and saves. Every learned fact passes through here, so the confidence guard is uniform:
    /// a one-off model hallucination gets weight 1 and never reaches a prompt until it repeats.
    func ingest(_ candidates: [UserMemoryCandidate]) {
        guard !candidates.isEmpty else { return }
        let stamp = now().timeIntervalSinceReferenceDate
        var changed = false
        for candidate in candidates where merge(candidate, at: stamp) {
            changed = true
        }
        if changed {
            pruneToCaps()
            save()
        }
    }

    /// The rendered profile line for the prompt, or nil when nothing is confident yet.
    func digest() -> String? {
        UserProfileDigest.make(from: facts)
    }

    /// Wipes all learned facts and persists the empty state.
    func clear() {
        guard !facts.isEmpty else {
            userDefaults.removeObject(forKey: Self.factsDefaultsKey)
            return
        }
        facts = []
        userDefaults.removeObject(forKey: Self.factsDefaultsKey)
    }

    // MARK: - Accumulation

    /// Minimum gap between weight bumps for the same fact. Weight is meant to count *independent*
    /// observations, but consecutive distillation snapshots overlap (the rolling buffer keeps recent
    /// text), so the same sentence can re-surface the same fact back to back — without this window a
    /// fact inflated to weight 13 in one sitting. Within the window only recency updates.
    private static let repeatObservationWindowSeconds: TimeInterval = 120

    /// Folds one candidate into the set: bumps the weight of a matching fact (same category, same
    /// value case-insensitively) or inserts it fresh. Returns whether the set changed.
    private func merge(_ candidate: UserMemoryCandidate, at stamp: TimeInterval) -> Bool {
        let normalized = candidate.value.lowercased()
        if let index = facts.firstIndex(where: {
            $0.category == candidate.category && $0.value.lowercased() == normalized
        }) {
            let previousSeen = facts[index].lastSeen
            facts[index].lastSeen = stamp
            if stamp - previousSeen >= Self.repeatObservationWindowSeconds {
                facts[index].weight = min(facts[index].weight + 1, Self.maxWeight)
            }
            return true
        }
        facts.append(
            UserMemoryFact(category: candidate.category, value: candidate.value, weight: 1, lastSeen: stamp)
        )
        return true
    }

    /// Keeps only the strongest `maxFactsPerCategory` facts in each category.
    private func pruneToCaps() {
        var kept: [UserMemoryFact] = []
        for category in UserMemoryFact.Category.allCases {
            let top = facts
                .filter { $0.category == category }
                .sorted { $0.weight == $1.weight ? $0.lastSeen > $1.lastSeen : $0.weight > $1.weight }
                .prefix(Self.maxFactsPerCategory)
            kept.append(contentsOf: top)
        }
        facts = kept
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(facts) else { return }
        userDefaults.set(data, forKey: Self.factsDefaultsKey)
    }

    private static func loadFacts(from defaults: UserDefaults) -> [UserMemoryFact] {
        guard let data = defaults.data(forKey: factsDefaultsKey),
              let decoded = try? JSONDecoder().decode([UserMemoryFact].self, from: data)
        else { return [] }
        return decoded
    }
}
