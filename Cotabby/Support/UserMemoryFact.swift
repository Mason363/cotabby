import Foundation

/// File overview:
/// One durable thing Cotabby has learned about the writer, accumulated on-device from what they
/// type. Facts are grouped by `Category` so the digest can order and phrase them, and each carries a
/// `weight` — how many independent times the same fact has been observed — so a repeated mention
/// beats one-off noise and only well-supported facts ever reach a prompt.
///
/// This is deliberately a tiny value type: learning (`UserMemoryDistiller`) and rendering
/// (`UserProfileDigest`) are pure and testable, while persistence and accumulation live in the
/// `@MainActor` `UserMemoryStore`. Keeping the fact `Codable` lets the store round-trip the whole
/// set through `UserDefaults` without a bespoke encoding.
nonisolated struct UserMemoryFact: Codable, Equatable, Sendable {
    /// The kind of fact, which fixes both its confidence threshold and where it lands in the digest.
    enum Category: String, Codable, Sendable, CaseIterable {
        /// The writer's name, e.g. "Mason". Extracted only from explicit "my name is" / "call me".
        case name
        /// Who the writer is or what they build, e.g. "a developer" or "builds macOS apps".
        case role
        /// Tools, languages, or hardware the writer uses, e.g. "Swift", "Xcode".
        case tools
        /// Things the writer likes or prefers, e.g. "dark mode".
        case preferences
        /// Where the writer is, e.g. "Toronto".
        case location
    }

    let category: Category
    /// The normalized fact value in its own casing (proper nouns preserved), phrased by the digest.
    var value: String
    /// Count of independent observations. Higher means more confident; capped by the store so an
    /// old fact cannot become unrepealable.
    var weight: Int
    /// Seconds since the reference date of the most recent observation, used for recency ordering.
    var lastSeen: TimeInterval
}

/// A single detected fact before it is merged into the persistent set — produced by the model
/// distiller (`UserMemoryDistiller.parse`) and consumed by `UserMemoryStore.ingest`, which assigns
/// weight and timestamp.
nonisolated struct UserMemoryCandidate: Equatable, Sendable {
    let category: UserMemoryFact.Category
    let value: String
}
