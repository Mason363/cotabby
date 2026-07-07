import XCTest
@testable import Cotabby

/// Tests the deterministic seam-spacing rule that replaces trusting the model's leading space.
final class CompletionSeamSpacingTests: XCTestCase {
    /// A closure over a fixed known-word set, matching the `!spellChecker.isTypo` shape.
    private func known(_ words: Set<String>) -> (String) -> Bool {
        { words.contains($0) }
    }

    func test_stripsSpaceWhenModelSplitAFragmentItShouldContinue() {
        // "hel" + " lo" → the join "hello" is a word but "hel" is not, so it is a continuation.
        let result = CompletionSeamSpacing.normalized(
            completion: " lo",
            precedingText: "hel",
            isKnownWord: known(["hello"])
        )
        XCTAssertEqual(result, "lo")
    }

    func test_addsSpaceWhenModelGluedANewWordOntoACompleteWord() {
        // "hello" + "world" → the join "helloworld" is not a word but "hello" is, so it is a new word.
        let result = CompletionSeamSpacing.normalized(
            completion: "world",
            precedingText: "hello",
            isKnownWord: known(["hello"])
        )
        XCTAssertEqual(result, " world")
    }

    func test_keepsContinuationWhenModelAndDictionaryAgree() {
        // "car" + "pet": model wanted no space, join "carpet" is a word — leave it glued.
        let result = CompletionSeamSpacing.normalized(
            completion: "pet",
            precedingText: "car",
            isKnownWord: known(["car", "carpet"])
        )
        XCTAssertEqual(result, "pet")
    }

    func test_preservesProperNounContinuationTheDictionaryCannotJudge() {
        // "Co" + "Tabby": neither the fragment nor the join is a known word, so trust the model's
        // no-space intent instead of forcing a split.
        let result = CompletionSeamSpacing.normalized(
            completion: "Tabby",
            precedingText: "Co",
            isKnownWord: known([])
        )
        XCTAssertEqual(result, "Tabby")
    }

    func test_neverAddsLeadingSpaceWhenPrecedingAlreadyEndsInWhitespace() {
        // The "type a space and get two" double: the preceding text already ends in a space, so the
        // completion must not carry its own — regardless of the model's leading space.
        let result = CompletionSeamSpacing.normalized(
            completion: " world",
            precedingText: "hello ",
            isKnownWord: known(["hello"])
        )
        XCTAssertEqual(result, "world")
    }

    func test_keepsModelSpaceAfterPunctuation() {
        // A punctuation seam is not the ambiguous word↔word case; keep the model's intent.
        let result = CompletionSeamSpacing.normalized(
            completion: " world",
            precedingText: "hello.",
            isKnownWord: known([])
        )
        XCTAssertEqual(result, " world")
    }

    func test_stripsMidWordHyphenArtifact() {
        // "sup" + "-posed": dropping the hyphen yields the real word "supposed", so the hyphen is a
        // decode artifact and must go.
        let result = CompletionSeamSpacing.normalized(
            completion: "-posed",
            precedingText: "where it's sup",
            isKnownWord: known(["supposed"])
        )
        XCTAssertEqual(result, "posed")
    }

    func test_keepsRealHyphenCompound() {
        // "so" + "-called": the dictionary does not know "socalled", so the model's hyphen is real.
        let result = CompletionSeamSpacing.normalized(
            completion: "-called",
            precedingText: "the so",
            isKnownWord: known(["so"])
        )
        XCTAssertEqual(result, "-called")
    }

    func test_keepsModelSpaceWhenBothWordsAreCompleteAndJoinIsNotAWord() {
        // "the" + " world": both are words and the join is not, so this is genuinely a new word;
        // keep the model's space rather than overriding.
        let result = CompletionSeamSpacing.normalized(
            completion: " world",
            precedingText: "the",
            isKnownWord: known(["the", "world"])
        )
        XCTAssertEqual(result, " world")
    }

    func test_noLeadingSpaceAtStartOfField() {
        let result = CompletionSeamSpacing.normalized(
            completion: "hello",
            precedingText: "",
            isKnownWord: known([])
        )
        XCTAssertEqual(result, "hello")
    }

    func test_emptyCompletionIsReturnedUnchanged() {
        let result = CompletionSeamSpacing.normalized(
            completion: "",
            precedingText: "hello",
            isKnownWord: known(["hello"])
        )
        XCTAssertEqual(result, "")
    }
}
