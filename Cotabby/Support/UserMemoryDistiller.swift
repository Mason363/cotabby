import Foundation

/// File overview:
/// Cotabby's on-device memory learner: it periodically hands a rolling snapshot of what the user has
/// actually been writing to the local model and asks it to name durable facts about the writer —
/// stated or *implied* ("heading home to Sudbury tonight" implies the location without anyone typing
/// "I live in Sudbury"). The model is the whole extraction engine on purpose; a deterministic
/// pattern-matcher was tried first and produced brittle junk, because people rarely describe
/// themselves in template sentences.
///
/// Cost and safety posture — this type never touches the model itself. It owns only the buffer, the
/// throttle, the prompt, and the parser, all pure and testable. The coordinator decides *when* to
/// spend a generation (only while the user is idle, so distillation never competes with a live
/// suggestion) and feeds the raw model text back to `parse`. Two guards keep the model honest:
/// `parse` rejects any fact whose content words do not literally appear in the snapshot (a base model
/// echoes its own few-shot examples and invents plausible facts), and `UserMemoryStore.ingest` weights
/// facts so nothing reaches a prompt on a single sighting.
///
/// The prompt is deliberately few-shot *completion*, not an instruction: the OSS engine drives a base
/// model that continues patterns rather than obeying commands, so we show it two worked examples and
/// let it continue the third. Instruct engines (Foundation Models, OpenAI-compatible) handle the same
/// shape at least as well.
nonisolated struct UserMemoryDistiller {
    /// How much recent writing to keep as distillation fuel. Bounded so the prompt stays cheap and the
    /// buffer cannot grow without limit.
    static let maxBufferCharacters = 2_400
    /// Minimum quiet gap between distillations. Snapshots should be frequent enough that a normal
    /// writing session yields several (facts need two independent sightings to surface), while
    /// staying a background cost, not a per-edit one.
    static let minInterval: TimeInterval = 90
    /// Minimum newly-written characters accumulated since the last distillation before another is
    /// worthwhile — no point re-reading nearly the same buffer.
    static let minNewCharacters = 120

    private(set) var buffer = ""
    private var charactersSinceLastDistill = 0
    private var lastDistillTime: Date = .distantPast

    /// Adds the latest field text to the rolling buffer. Because the prediction path passes the whole
    /// preceding text each time, we append only the part we have not already seen (the growth), then
    /// trim the buffer to its cap keeping the most recent end.
    mutating func record(text: String) {
        let addition: String
        if let range = buffer.range(of: text) {
            // Text we already contain (the user is still in the same field): nothing new.
            _ = range
            addition = ""
        } else if !buffer.isEmpty, text.hasPrefix(buffer) {
            addition = String(text.dropFirst(buffer.count))
        } else if !text.isEmpty, buffer.hasSuffix(text) {
            addition = ""
        } else {
            // A new field or a divergent edit: separate with a newline so facts don't bleed together.
            addition = buffer.isEmpty ? text : "\n" + text
        }
        guard !addition.isEmpty else { return }

        buffer += addition
        charactersSinceLastDistill += addition.count
        if buffer.count > Self.maxBufferCharacters {
            buffer = String(buffer.suffix(Self.maxBufferCharacters))
        }
    }

    /// Whether enough new writing has piled up and enough time has passed to justify a distillation.
    func isDue(now: Date) -> Bool {
        guard charactersSinceLastDistill >= Self.minNewCharacters else { return false }
        guard now.timeIntervalSince(lastDistillTime) >= Self.minInterval else { return false }
        return !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Resets the throttle window after a distillation attempt (whether or not it yielded facts), so a
    /// barren buffer is not retried every idle tick.
    mutating func markDistilled(now: Date) {
        lastDistillTime = now
        charactersSinceLastDistill = 0
    }

    /// The few-shot completion prompt for the current buffer, or nil when there is nothing to distill.
    func makePrompt() -> String? {
        let fuel = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fuel.isEmpty else { return nil }
        return """
        List durable facts about the writer using "category: value" lines. Categories: name, role, \
        tools, preferences, location. Facts may be implied rather than stated, but must be about the \
        writer and use words from the text. Write "none" if there are none.

        Text: Hey team, I'm Sarah. I mostly use Figma and Notion, and I'm based in Berlin.
        Facts:
        name: Sarah
        tools: Figma
        tools: Notion
        location: Berlin

        Text: honestly been deep in Rust lately, my little database engine finally parses. \
        Long drive home to Osaka tomorrow.
        Facts:
        tools: Rust
        role: building a database engine
        location: Osaka

        Text: \(fuel)
        Facts:
        """
    }

    /// Parses the model's completion into candidates. Accepts only well-formed "category: value" lines
    /// with a known category and a sane value, and stops at the first blank line or a hallucinated new
    /// "Text:" example, so trailing model rambling is ignored.
    ///
    /// `buffer` is the exact text the prompt was built from, and it is the grounding rule: most of a
    /// candidate value's content words must literally appear in it (see `isGrounded`). A base model
    /// routinely echoes the prompt's few-shot examples ("Sarah", "Figma", "Berlin") or invents
    /// plausible-sounding facts; neither appears in what the user actually typed, so this check
    /// deletes whole classes of false memories at once, while still admitting facts the model merely
    /// rephrased or inferred from the user's own words.
    func parse(_ response: String, buffer: String) -> [UserMemoryCandidate] {
        let groundingText = buffer.lowercased()
        var candidates: [UserMemoryCandidate] = []
        var started = false
        for rawLine in response.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // Skip leading blank lines a base model often emits; a blank *after* facts ends the list.
                if started { break }
                continue
            }
            let lowerLine = line.lowercased()
            // Stop if the model hallucinates a new example or declares no facts.
            if lowerLine.hasPrefix("text:") || lowerLine == "none" { break }

            guard let separator = line.firstIndex(of: ":") else { continue }
            let categoryToken = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = normalizeValue(String(line[line.index(after: separator)...]))
            guard let category = category(for: categoryToken), let value else { continue }
            guard isGrounded(value, in: groundingText) else { continue }
            candidates.append(UserMemoryCandidate(category: category, value: value))
            started = true
            if candidates.count >= 8 { break }
        }
        return candidates
    }

    /// Grounding check: a MAJORITY of the value's content words (3+ characters) must appear in the
    /// lowercased buffer. Majority, not all, so the model may legitimately rephrase an implied fact
    /// ("building a database engine" for text that says "my database engine finally parses" — 2 of 3
    /// words grounded) while a pure invention or an echoed prompt example ("Sarah", "Berlin" — 0
    /// grounded) is still rejected outright. Short glue words ("a", "of") are exempt.
    private func isGrounded(_ value: String, in groundingText: String) -> Bool {
        let contentWords = value
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 3 }
        guard !contentWords.isEmpty else { return false }
        let groundedCount = contentWords.filter { groundingText.contains($0) }.count
        return groundedCount * 2 > contentWords.count
    }

    // MARK: - Parsing helpers

    private func category(for token: String) -> UserMemoryFact.Category? {
        switch token {
        case "name": return .name
        case "role", "occupation", "job": return .role
        case "tools", "tool", "tech", "technology", "languages", "language": return .tools
        case "preferences", "preference", "likes", "like": return .preferences
        case "location", "place", "city": return .location
        default: return nil
        }
    }

    /// Trims a parsed value and rejects empties, over-long junk, and placeholder tokens the model may
    /// echo from the instructions.
    private func normalizeValue(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'.,;"))
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.count >= 2, cleaned.count <= 48 else { return nil }
        let lower = cleaned.lowercased()
        guard lower != "none", lower != "value", lower != "unknown", lower != "n/a" else { return nil }
        return cleaned
    }
}
