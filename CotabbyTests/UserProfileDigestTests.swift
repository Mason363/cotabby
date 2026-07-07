import XCTest
@testable import Cotabby

/// Tests how accumulated facts are gated by confidence and phrased into the prompt line.
final class UserProfileDigestTests: XCTestCase {
    private func fact(
        _ category: UserMemoryFact.Category,
        _ value: String,
        weight: Int,
        lastSeen: TimeInterval = 0
    ) -> UserMemoryFact {
        UserMemoryFact(category: category, value: value, weight: weight, lastSeen: lastSeen)
    }

    func test_emptyFactsProduceNoLine() {
        XCTAssertNil(UserProfileDigest.make(from: []))
    }

    func test_composesIdentityAndActivityWithWho() {
        let line = UserProfileDigest.make(from: [
            fact(.role, "a developer", weight: 2),
            fact(.role, "builds macOS apps", weight: 2)
        ])
        XCTAssertEqual(line, "About the writer: a developer who builds macOS apps.")
    }

    func test_fullProfileRendersInCategoryOrder() {
        let line = UserProfileDigest.make(from: [
            fact(.name, "Mason", weight: 2),
            fact(.role, "a developer", weight: 2),
            fact(.role, "builds macOS apps", weight: 2),
            fact(.tools, "Swift", weight: 2),
            fact(.tools, "Xcode", weight: 2),
            fact(.preferences, "dark mode", weight: 2),
            fact(.location, "Toronto", weight: 2)
        ])
        XCTAssertEqual(
            line,
            "About the writer: a developer who builds macOS apps; uses Swift, Xcode; "
                + "likes dark mode; based in Toronto; name is Mason."
        )
    }

    func test_toolsBelowThresholdAreExcluded() {
        // Every category needs weight >= 2; a single mention must not surface.
        XCTAssertNil(UserProfileDigest.make(from: [fact(.tools, "Swift", weight: 1)]))
    }

    func test_singleObservationsNeverSurface() {
        // One sighting is exactly the profile of junk (a stray match, a one-off mention); no
        // category may reach a prompt on a single observation.
        XCTAssertNil(UserProfileDigest.make(from: [
            fact(.name, "Gemini", weight: 1),
            fact(.role, "user", weight: 1),
            fact(.location, "Su", weight: 1)
        ]))
        XCTAssertEqual(
            UserProfileDigest.make(from: [fact(.role, "a designer", weight: 2)]),
            "About the writer: a designer."
        )
    }

    func test_higherWeightToolsRankFirst() {
        let line = UserProfileDigest.make(from: [
            fact(.tools, "Swift", weight: 5),
            fact(.tools, "Rust", weight: 2),
            fact(.tools, "Go", weight: 3)
        ])
        XCTAssertEqual(line, "About the writer: uses Swift, Go, Rust.")
    }

    func test_lineIsLengthCapped() {
        let facts = (0..<40).map { fact(.preferences, "preference number \($0)", weight: 3, lastSeen: TimeInterval($0)) }
        let line = UserProfileDigest.make(from: facts)
        XCTAssertNotNil(line)
        XCTAssertLessThanOrEqual(line!.count, UserProfileDigest.maxCharacters)
    }
}
