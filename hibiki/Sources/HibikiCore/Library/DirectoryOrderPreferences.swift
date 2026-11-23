import Foundation

public enum DirectoryOrderScope: String, Sendable {
    case creators, circles, performers
}

public enum DirectoryOrderError: LocalizedError {
    case staleOrder
    public var errorDescription: String? { InterfaceLocalization.text("列表内容已变化，请重新调整。") }
}

/// Stable identities (creator IDs or prefixed tag names), kept separately for each directory.
/// A filtered reorder changes only the visible slots in the complete catalog.
public final class DirectoryOrderPreferences {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ scope: DirectoryOrderScope) -> String { "library.directoryOrder.\(scope.rawValue)" }

    public func resolved(_ availableIDs: [String], scope: DirectoryOrderScope) -> [String] {
        var seen = Set<String>()
        let available = availableIDs.filter { seen.insert($0).inserted }
        let allowed = Set(available)
        seen = []
        let saved = (defaults.stringArray(forKey: key(scope)) ?? [])
            .filter { allowed.contains($0) && seen.insert($0).inserted }
        return saved + available.filter { !seen.contains($0) }
    }

    @discardableResult
    public func reorder(_ ids: [String], visibleIDs: [String], allIDs: [String],
                        scope: DirectoryOrderScope) throws -> [String] {
        let current = resolved(allIDs, scope: scope)
        let subset = Set(visibleIDs)
        guard !visibleIDs.isEmpty, Set(allIDs).count == allIDs.count,
              subset.count == visibleIDs.count, ids.count == visibleIDs.count,
              Set(ids) == subset, subset.isSubset(of: Set(allIDs)),
              current.filter({ subset.contains($0) }) == visibleIDs else {
            throw DirectoryOrderError.staleOrder
        }
        var replacements = ids.makeIterator()
        let result = current.map { subset.contains($0) ? replacements.next()! : $0 }
        if result != current { defaults.set(result, forKey: key(scope)) }
        return result
    }
}
