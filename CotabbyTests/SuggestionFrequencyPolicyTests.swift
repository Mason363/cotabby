import XCTest
@testable import Cotabby

/// Tests the caret-position gate behind the user-facing suggestion-frequency control.
final class SuggestionFrequencyPolicyTests: XCTestCase {
    private func allows(_ preceding: String, _ trailing: String, _ frequency: SuggestionFrequency) -> Bool {
        SuggestionFrequencyPolicy.allows(precedingText: preceding, trailingText: trailing, frequency: frequency)
    }

    // MARK: - Often (default, maximal)

    func test_oftenAlwaysAllows() {
        XCTAssertTrue(allows("h", "", .often))            // first letter of a word
        XCTAssertTrue(allows("hel", "lo", .often))        // strictly mid-word
        XCTAssertTrue(allows("hello ", "", .often))       // at a boundary
    }

    // MARK: - Balanced (skip the first-letter moment)

    func test_balancedSkipsFirstLetterOfAWord() {
        XCTAssertFalse(allows("hello w", "", .balanced))  // exactly one letter into "w"
    }

    func test_balancedAllowsBoundaryAndDeeperWords() {
        XCTAssertTrue(allows("hello ", "", .balanced))    // predicting a fresh word
        XCTAssertTrue(allows("hello wo", "", .balanced))  // two letters in
    }

    // MARK: - Relaxed (boundaries and word-ends only)

    func test_relaxedAllowsFreshBoundary() {
        XCTAssertTrue(allows("hello ", "", .relaxed))
    }

    func test_relaxedBlocksShortInProgressWord() {
        XCTAssertFalse(allows("hello w", "", .relaxed))   // 1 letter, not a boundary
        XCTAssertFalse(allows("hello wor", "", .relaxed)) // 3 letters, still short
    }

    func test_relaxedAllowsDeepWord() {
        XCTAssertTrue(allows("hello worl", "", .relaxed)) // 4 letters into the word
    }

    func test_relaxedBlocksStrictlyMidWord() {
        XCTAssertFalse(allows("hel", "lo", .relaxed))     // word chars on both sides
        XCTAssertFalse(allows("develop", "ment", .relaxed))
    }

    // MARK: - Persistence

    func test_currentDefaultsToOftenWhenUnset() {
        let defaults = UserDefaults(suiteName: "FrequencyTests-\(UUID().uuidString)")!
        XCTAssertEqual(SuggestionFrequencyPolicy.current(from: defaults), .often)
    }

    func test_currentReadsStoredValueAndIgnoresGarbage() {
        let defaults = UserDefaults(suiteName: "FrequencyTests-\(UUID().uuidString)")!
        defaults.set(SuggestionFrequency.relaxed.rawValue, forKey: SuggestionFrequencyPolicy.defaultsKey)
        XCTAssertEqual(SuggestionFrequencyPolicy.current(from: defaults), .relaxed)

        defaults.set("nonsense", forKey: SuggestionFrequencyPolicy.defaultsKey)
        XCTAssertEqual(SuggestionFrequencyPolicy.current(from: defaults), .often)
    }
}
