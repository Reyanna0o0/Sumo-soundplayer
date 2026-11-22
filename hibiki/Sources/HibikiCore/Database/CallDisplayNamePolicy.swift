import Foundation

/// Display-only fallback policy for the simulated call screen's name label.
///
/// Resolves the most specific usable name without touching stored data:
/// 1. A nonblank role name (trimmed) wins.
/// 2. Otherwise, for a personal work, exactly one nonblank creator name
///    (trimmed) is used; for a collection work, exactly one nonblank performer
///    name (trimmed) is used. The opposite list is ignored. Two or more
///    nonblank entries are ambiguous, even when the strings are equal; entries
///    are never deduplicated.
/// 3. Otherwise a nonblank work title (trimmed).
/// 4. Finally `通话中`.
///
/// Inputs are never mutated, and no upload account is inferred from them.
public enum CallDisplayNamePolicy {

    /// The final fallback shown when no role, single creator/performer, or
    /// work title is available.
    public static var fallbackName: String { InterfaceLocalization.text("通话中") }

    public static func resolve(
        roleName: String?,
        isPersonal: Bool,
        creatorNames: [String],
        performerNames: [String],
        workTitle: String
    ) -> String {
        if let role = nonblank(roleName) {
            return role
        }

        let candidates = isPersonal ? creatorNames : performerNames
        let nonblankCandidates = candidates.compactMap(nonblank)
        if nonblankCandidates.count == 1, let only = nonblankCandidates.first {
            return only
        }

        if let title = nonblank(workTitle) {
            return title
        }

        return fallbackName
    }

    /// Returns the value with leading/trailing whitespace and newlines removed,
    /// or `nil` when the result is empty.
    private static func nonblank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
