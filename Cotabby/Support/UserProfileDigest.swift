import Foundation

/// File overview:
/// Renders the accumulated `UserMemoryFact` set into one compact declarative line for the base-model
/// prompt: "About the writer: a developer who builds macOS apps; uses Swift, Xcode; likes dark mode;
/// based in Toronto; name is Mason."
///
/// Two things make this the right shape for the pipeline:
///
/// - **Declarative, not instructional.** Like the persona and surface lines it sits beside, it
///   *describes* the writer so a base model conditions on it, rather than commanding a model that
///   cannot follow commands.
/// - **Stable across keystrokes.** The line only changes when a *new* fact crosses its confidence
///   threshold, so placed at the head of the prompt it is amortized by llama's KV-cache prefix reuse
///   — the "store it as raw data so every token is faster" intuition, realized for free.
///
/// Confidence gating lives here: a fact is only surfaced once its weight reaches the per-category
/// threshold, so a single stray match never reaches a prompt.
nonisolated enum UserProfileDigest {
    /// Hard cap on the rendered line so a chatty profile can never crowd the budgeted preface.
    static let maxCharacters = 260

    /// Minimum observation count before a fact is trusted enough to surface: two *independent*
    /// observations for every category (the store's repeat window guarantees independence). One
    /// observation is exactly the profile of the junk that reached prompts in practice — a stray
    /// extractor match, or a distiller line about something merely mentioned once — and a real fact
    /// about the writer recurs by nature, so the second sighting costs little and filters a lot.
    private static func minimumWeight(for category: UserMemoryFact.Category) -> Int {
        switch category {
        case .name, .location, .role, .tools, .preferences: return 2
        }
    }

    /// Builds the "About the writer: …" line, or nil when nothing has cleared its threshold yet.
    static func make(from facts: [UserMemoryFact]) -> String? {
        var clauses: [String] = []
        if let role = roleClause(from: facts) { clauses.append(role) }
        if let tools = toolsClause(from: facts) { clauses.append(tools) }
        if let prefs = preferencesClause(from: facts) { clauses.append(prefs) }
        if let location = locationClause(from: facts) { clauses.append(location) }
        if let name = nameClause(from: facts) { clauses.append(name) }

        guard !clauses.isEmpty else { return nil }
        let line = "About the writer: " + clauses.joined(separator: "; ") + "."
        return String(line.prefix(maxCharacters))
    }

    // MARK: - Clauses

    /// Splits role facts into an identity ("a developer") and an activity ("builds macOS apps") and
    /// joins them with "who" for a natural reading; falls back to whichever exists.
    private static func roleClause(from facts: [UserMemoryFact]) -> String? {
        let roles = confident(facts, in: .role)
        guard !roles.isEmpty else { return nil }
        let identity = roles.first { hasArticlePrefix($0) }
        let activity = roles.first { !hasArticlePrefix($0) }
        switch (identity, activity) {
        case let (identity?, activity?):
            return "\(identity) who \(activity)"
        case let (identity?, nil):
            return identity
        case let (nil, activity?):
            return activity
        default:
            return nil
        }
    }

    private static func toolsClause(from facts: [UserMemoryFact]) -> String? {
        let tools = Array(confident(facts, in: .tools).prefix(3))
        return tools.isEmpty ? nil : "uses " + tools.joined(separator: ", ")
    }

    private static func preferencesClause(from facts: [UserMemoryFact]) -> String? {
        let prefs = Array(confident(facts, in: .preferences).prefix(3))
        return prefs.isEmpty ? nil : "likes " + prefs.joined(separator: ", ")
    }

    private static func locationClause(from facts: [UserMemoryFact]) -> String? {
        confident(facts, in: .location).first.map { "based in \($0)" }
    }

    private static func nameClause(from facts: [UserMemoryFact]) -> String? {
        confident(facts, in: .name).first.map { "name is \($0)" }
    }

    // MARK: - Selection

    /// The values in `category` whose weight clears the threshold, ordered strongest-and-newest first.
    private static func confident(
        _ facts: [UserMemoryFact],
        in category: UserMemoryFact.Category
    ) -> [String] {
        facts
            .filter { $0.category == category && $0.weight >= minimumWeight(for: category) }
            .sorted { lhs, rhs in
                // Weight first, then recency, then value as a stable final tiebreak so the rendered
                // line is deterministic (Swift's sort is not guaranteed stable for equal keys).
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.value < rhs.value
            }
            .map(\.value)
    }

    private static func hasArticlePrefix(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("a ") || lower.hasPrefix("an ")
    }
}
