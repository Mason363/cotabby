import Foundation

/// File overview:
/// Decides the single correct amount of whitespace at the seam between the user's preceding text and
/// a model completion — zero or one space — rather than trusting the model's own leading space.
///
/// Why this exists:
/// A base model's leading space is an unreliable signal for "start a new word" vs. "continue the word
/// I'm typing." It errs in both directions: it splits a fragment it should have continued
/// (`"hel"` + `" lo"` → "hel lo"), and it glues a new word onto a complete one
/// (`"hello"` + `"world"` → "helloworld"). Both read as broken spacing. So we ignore the model's
/// guess and derive the seam from the text, correcting the model only when a spell check *strongly*
/// disagrees. Staying conservative preserves proper nouns and novel joins the dictionary cannot judge
/// (`"Co"` + `"Tabby"` → "CoTabby"), where the model's intent is the best signal we have.
///
/// This also removes the "type a space and get two" double: a completion never carries a leading
/// space into a boundary that already ends in whitespace, so the typed space is the only one.
nonisolated enum CompletionSeamSpacing {
    /// Returns `completion` with its leading whitespace replaced by the correct seam for
    /// `precedingText`. `isKnownWord` is injected so the rule stays pure and the caller picks the
    /// spell-checking backend (Cotabby passes the same NSSpellChecker the seam guard uses).
    static func normalized(
        completion: String,
        precedingText: String,
        isKnownWord: (String) -> Bool
    ) -> String {
        let modelWantedSpace = completion.first?.isWhitespace ?? false
        let body = String(completion.drop(while: { $0.isWhitespace }))
        guard !body.isEmpty else { return completion }

        // Start of field, or an existing boundary (the preceding text already ends in whitespace or a
        // newline): never introduce a leading space. This is the rule that stops a typed space from
        // producing a double space at the seam.
        guard let lastChar = precedingText.last, !lastChar.isWhitespace else {
            return body
        }

        // Mid-word hyphen artifact: continuing "sup" the model sometimes emits "-posed", which would
        // render the typo "sup-posed". When dropping the hyphen yields a real word ("supposed"), the
        // hyphen is the artifact — strip it and continue the word directly. A join the dictionary
        // does not know keeps the model's hyphen, so real compounds ("so-called") stay intact.
        if isWordCharacter(lastChar), !modelWantedSpace, body.first == "-" {
            let afterHyphen = String(body.dropFirst())
            if let firstAfter = afterHyphen.first, isWordCharacter(firstAfter),
               isKnownWord(trailingWord(of: precedingText) + leadingWord(of: afterHyphen)) {
                return afterHyphen
            }
        }

        // Only a word-character ↔ word-character seam is ambiguous. If the completion opens with
        // punctuation, or the preceding text ends in punctuation, the model's intent is the right call.
        guard isWordCharacter(lastChar),
              let firstBody = body.first, isWordCharacter(firstBody)
        else {
            return (modelWantedSpace ? " " : "") + body
        }

        let lastWord = trailingWord(of: precedingText)
        let firstToken = leadingWord(of: body)
        let joinedIsWord = isKnownWord(lastWord + firstToken)
        let lastWordIsWord = isKnownWord(lastWord)

        if modelWantedSpace, joinedIsWord, !lastWordIsWord {
            // The model split a fragment it should have continued: "hel" + " lo" → "hello".
            return body
        }
        if !modelWantedSpace, !joinedIsWord, lastWordIsWord {
            // The model glued a new word onto a complete one: "hello" + "world" → "hello world".
            return " " + body
        }
        // Ambiguous, or the dictionary agrees with the model: keep the model's intent.
        return (modelWantedSpace ? " " : "") + body
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func trailingWord(of text: String) -> String {
        String(text.reversed().prefix(while: { isWordCharacter($0) }).reversed())
    }

    private static func leadingWord(of text: String) -> String {
        String(text.prefix(while: { isWordCharacter($0) }))
    }
}
