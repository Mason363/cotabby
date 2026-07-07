import XCTest
@testable import Cotabby

/// Tests the pure buffer/throttle/prompt/parse core of the model-based memory distiller.
final class UserMemoryDistillerTests: XCTestCase {
    // MARK: - Buffer

    func test_recordAppendsOnlyTheGrowthOfTheSameField() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: "Hello there")
        distiller.record(text: "Hello there, friend")
        XCTAssertEqual(distiller.buffer, "Hello there, friend")
    }

    func test_recordSeparatesADivergentField() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: "first field")
        distiller.record(text: "totally different second field")
        XCTAssertEqual(distiller.buffer, "first field\ntotally different second field")
    }

    func test_recordIgnoresUnchangedText() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: "same text")
        distiller.record(text: "same text")
        XCTAssertEqual(distiller.buffer, "same text")
    }

    func test_bufferIsCappedToMostRecentText() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: String(repeating: "a", count: UserMemoryDistiller.maxBufferCharacters + 500))
        XCTAssertLessThanOrEqual(distiller.buffer.count, UserMemoryDistiller.maxBufferCharacters)
    }

    // MARK: - Throttle

    func test_notDueUntilEnoughNewText() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: "short")
        XCTAssertFalse(distiller.isDue(now: Date(timeIntervalSinceReferenceDate: 10_000)))
    }

    func test_dueAfterEnoughTextAndTime() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: String(repeating: "word ", count: 60)) // > minNewCharacters
        XCTAssertTrue(distiller.isDue(now: Date(timeIntervalSinceReferenceDate: 10_000)))
    }

    func test_markDistilledResetsTheWindow() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: String(repeating: "word ", count: 60))
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        distiller.markDistilled(now: now)
        // Immediately after, neither enough new text nor enough elapsed time.
        XCTAssertFalse(distiller.isDue(now: now))
    }

    // MARK: - Prompt

    func test_promptIsNilForEmptyBuffer() {
        let distiller = UserMemoryDistiller()
        XCTAssertNil(distiller.makePrompt())
    }

    func test_promptContainsBufferText() {
        var distiller = UserMemoryDistiller()
        distiller.record(text: "I have been researching compilers all week")
        let prompt = distiller.makePrompt()
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt!.contains("researching compilers"))
        XCTAssertTrue(prompt!.contains("Facts:"))
    }

    // MARK: - Parse

    func test_parsesWellFormedFacts() {
        let distiller = UserMemoryDistiller()
        let buffer = "Hi, I'm Mason. I write Swift all day and it builds a compiler for fun."
        let candidates = distiller.parse("name: Mason\ntools: Swift\nrole: builds a compiler", buffer: buffer)
        XCTAssertEqual(candidates, [
            .init(category: .name, value: "Mason"),
            .init(category: .tools, value: "Swift"),
            .init(category: .role, value: "builds a compiler")
        ])
    }

    func test_parseSkipsLeadingBlankLineAndStopsAtBlank() {
        let distiller = UserMemoryDistiller()
        let candidates = distiller.parse(
            "\nname: Alex\n\ntools: ignored after blank",
            buffer: "call me Alex, and I use ignored after blank tools"
        )
        XCTAssertEqual(candidates, [.init(category: .name, value: "Alex")])
    }

    func test_parseStopsAtHallucinatedNewExample() {
        let distiller = UserMemoryDistiller()
        let candidates = distiller.parse(
            "tools: Rust\nText: some other person\nname: Nobody",
            buffer: "been writing Rust lately, Nobody knows"
        )
        XCTAssertEqual(candidates, [.init(category: .tools, value: "Rust")])
    }

    func test_parseHandlesNone() {
        let distiller = UserMemoryDistiller()
        XCTAssertTrue(distiller.parse("none", buffer: "whatever text").isEmpty)
    }

    func test_parseMapsCategorySynonyms() {
        let distiller = UserMemoryDistiller()
        let candidates = distiller.parse(
            "language: Python\noccupation: a teacher\ncity: Osaka",
            buffer: "I am a teacher in Osaka and I teach Python"
        )
        XCTAssertEqual(candidates, [
            .init(category: .tools, value: "Python"),
            .init(category: .role, value: "a teacher"),
            .init(category: .location, value: "Osaka")
        ])
    }

    func test_parseRejectsPlaceholderAndJunkValues() {
        let distiller = UserMemoryDistiller()
        let candidates = distiller.parse(
            "name: none\ntools: x\nlocation: unknown",
            buffer: "none x unknown"
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func test_parseIgnoresUnknownCategory() {
        let distiller = UserMemoryDistiller()
        let candidates = distiller.parse(
            "mood: happy\ntools: Xcode",
            buffer: "spent the evening happy inside Xcode"
        )
        XCTAssertEqual(candidates, [.init(category: .tools, value: "Xcode")])
    }

    func test_parseAcceptsRephrasedFactGroundedByMajorityOfWords() {
        // Inference is the point of model-driven memory: the user never types "I live in Sudbury",
        // but "driving home to Sudbury tonight" grounds "location: Sudbury", and a rephrased role
        // passes when most of its content words come from the text.
        let distiller = UserMemoryDistiller()
        let candidates = distiller.parse(
            "location: Sudbury\nrole: building a database engine",
            buffer: "long drive home to Sudbury tonight, my little database engine finally parses"
        )
        XCTAssertEqual(candidates, [
            .init(category: .location, value: "Sudbury"),
            .init(category: .role, value: "building a database engine")
        ])
    }

    func test_parseRejectsFactsNotGroundedInTheBuffer() {
        // The classic failure: a base model echoes the prompt's own few-shot example ("Sarah",
        // "Figma", "Berlin") or invents a fact. None of it appears in what the user actually typed,
        // so every ungrounded line must be dropped; the grounded one survives.
        let distiller = UserMemoryDistiller()
        let candidates = distiller.parse(
            "name: Sarah\ntools: Figma\nlocation: Berlin\ntools: Xcode",
            buffer: "I spent all day in Xcode debugging the overlay"
        )
        XCTAssertEqual(candidates, [.init(category: .tools, value: "Xcode")])
    }
}
