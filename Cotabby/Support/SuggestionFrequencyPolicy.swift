import Foundation

/// How eagerly Cotabby offers ghost text, exposed to the user as a frequency control.
///
/// Cotabby already generates on every keystroke (post-debounce) once the field has any text, so
/// `.often` — the default — preserves that maximal behavior and never suppresses. The lower settings
/// exist for users who find per-keystroke suggestions too chatty: they hold suggestions back until the
/// caret reaches a more meaningful position (past the first letter of a word, or a word boundary),
/// which cuts visual churn without changing what the model produces.
nonisolated enum SuggestionFrequency: String, CaseIterable, Codable, Sendable {
    /// Suggest on every keystroke — the historical, maximal behavior. Default.
    case often
    /// Skip the noisy first-letter-of-a-word moment; suggest once a word is under way or at a boundary.
    case balanced
    /// Only suggest at word boundaries or deep inside a long word, for the least visual churn.
    case relaxed

    /// User-facing label for the menu control.
    var label: String {
        switch self {
        case .often: return "Often"
        case .balanced: return "Balanced"
        case .relaxed: return "Relaxed"
        }
    }
}

/// Pure gate deciding whether the current caret position warrants a suggestion at a given frequency.
/// Kept separate from the coordinator so the thresholds are trivially testable and free of app state.
nonisolated enum SuggestionFrequencyPolicy {
    /// Defaults key for the user's choice; absent means `.often` (opt-out of dialing back), so the
    /// shipped behavior is unchanged until the user picks a calmer setting.
    static let defaultsKey = "cotabbySuggestionFrequency"

    /// The user's current choice, defaulting to `.often` when unset or unrecognized.
    static func current(from defaults: UserDefaults) -> SuggestionFrequency {
        guard let raw = defaults.string(forKey: defaultsKey),
              let frequency = SuggestionFrequency(rawValue: raw)
        else { return .often }
        return frequency
    }

    /// Whether a suggestion should be generated for this caret context. `precedingText`/`trailingText`
    /// are the live text on each side of the caret. Upstream has already required non-whitespace
    /// preceding text, so `.often` is an unconditional yes.
    static func allows(
        precedingText: String,
        trailingText: String,
        frequency: SuggestionFrequency
    ) -> Bool {
        switch frequency {
        case .often:
            return true
        case .balanced:
            // Suppress only the single-first-letter moment: a boundary (0 trailing word chars, i.e.
            // predicting a fresh word) is fine, and a word already 2+ letters in is fine; exactly one
            // typed letter is the chatty case we skip.
            return trailingWordLength(of: precedingText) != 1
        case .relaxed:
            // Only at a fresh word boundary, or once deep (4+ letters) into the current word, and
            // never strictly mid-word (a word character on both sides of the caret).
            if isStrictlyMidWord(precedingText: precedingText, trailingText: trailingText) {
                return false
            }
            let wordLength = trailingWordLength(of: precedingText)
            return wordLength == 0 || wordLength >= 4
        }
    }

    // MARK: - Helpers

    /// Length of the unbroken run of word characters immediately before the caret. 0 when the caret
    /// sits right after whitespace or punctuation (i.e. at a fresh word boundary).
    private static func trailingWordLength(of text: String) -> Int {
        text.reversed().prefix(while: isWordCharacter).count
    }

    /// True when a word character sits on both sides of the caret — the caret is inside a word.
    private static func isStrictlyMidWord(precedingText: String, trailingText: String) -> Bool {
        guard let before = precedingText.last, isWordCharacter(before) else { return false }
        guard let after = trailingText.first, isWordCharacter(after) else { return false }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
