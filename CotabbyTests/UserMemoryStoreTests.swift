import XCTest
@testable import Cotabby

/// Tests accumulation, weight independence, persistence, and opt-out for the on-device memory store.
@MainActor
final class UserMemoryStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "UserMemoryStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func candidate(
        _ category: UserMemoryFact.Category,
        _ value: String
    ) -> UserMemoryCandidate {
        UserMemoryCandidate(category: category, value: value)
    }

    func test_accumulatesWeightOnIndependentIngests() {
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let store = UserMemoryStore(userDefaults: makeDefaults(), now: { clock })

        store.ingest([candidate(.tools, "Swift")])
        clock.addTimeInterval(180) // past the repeat-observation window: an independent sighting
        store.ingest([candidate(.tools, "Swift")])

        let swift = store.facts.first { $0.category == .tools && $0.value == "Swift" }
        XCTAssertEqual(swift?.weight, 2)
    }

    func test_reingestWithinTheRepeatWindowDoesNotInflateWeight() {
        // Consecutive distillation snapshots overlap, so the same fact can re-surface back to back.
        // Weight must count independent sightings, not snapshots.
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let store = UserMemoryStore(userDefaults: makeDefaults(), now: { clock })

        store.ingest([candidate(.tools, "Swift")])
        clock.addTimeInterval(5) // same sitting
        store.ingest([candidate(.tools, "Swift")])

        let swift = store.facts.first { $0.category == .tools && $0.value == "Swift" }
        XCTAssertEqual(swift?.weight, 1, "Same-sitting repeats refresh recency, not weight")
    }

    func test_digestSurfacesOnceFactCrossesThreshold() {
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let store = UserMemoryStore(userDefaults: makeDefaults(), now: { clock })

        store.ingest([candidate(.tools, "Rust")])
        XCTAssertNil(store.digest(), "A single sighting is below threshold")

        clock.addTimeInterval(180)
        store.ingest([candidate(.tools, "Rust")])
        XCTAssertEqual(store.digest(), "About the writer: uses Rust.")
    }

    func test_matchIsCaseInsensitiveButKeepsFirstCasing() {
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let store = UserMemoryStore(userDefaults: makeDefaults(), now: { clock })

        store.ingest([candidate(.name, "Mason")])
        clock.addTimeInterval(180)
        store.ingest([candidate(.name, "mason")])

        XCTAssertEqual(store.facts.filter { $0.category == .name }.count, 1)
        XCTAssertEqual(store.facts.first { $0.category == .name }?.weight, 2)
        XCTAssertEqual(store.facts.first { $0.category == .name }?.value, "Mason")
    }

    func test_clearWipesFactsAndPersists() {
        let defaults = makeDefaults()
        let store = UserMemoryStore(userDefaults: defaults, now: { Date(timeIntervalSinceReferenceDate: 0) })
        store.ingest([candidate(.name, "Mason")])
        XCTAssertFalse(store.facts.isEmpty)

        store.clear()
        XCTAssertTrue(store.facts.isEmpty)

        // A fresh store over the same defaults sees the cleared state.
        let reloaded = UserMemoryStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.facts.isEmpty)
    }

    func test_factsPersistAcrossStoreInstances() {
        let defaults = makeDefaults()
        let first = UserMemoryStore(userDefaults: defaults, now: { Date(timeIntervalSinceReferenceDate: 0) })
        first.ingest([candidate(.name, "Mason")])

        let reloaded = UserMemoryStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.facts.first { $0.category == .name }?.value, "Mason")
    }

    func test_isEnabledDefaultsToTrueWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertTrue(UserMemoryStore.isEnabled(defaults: defaults))

        defaults.set(false, forKey: UserMemoryStore.enabledDefaultsKey)
        XCTAssertFalse(UserMemoryStore.isEnabled(defaults: defaults))
    }
}
