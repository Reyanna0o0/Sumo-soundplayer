import Foundation

/// Each library has its own selected sort and full custom order. IDs are stored
/// as decimal strings so UserDefaults never rounds an Int64 through a Double.
final class WorkOrderPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func sortKey(_ library: MediaLibraryKind) -> String { "library.workSort.\(library.rawValue)" }
    static func customKey(_ library: MediaLibraryKind) -> String { "library.customWorkOrder.\(library.rawValue)" }

    func selectedSort(for library: MediaLibraryKind) -> WorkSortOrder {
        guard let raw = defaults.string(forKey: Self.sortKey(library)),
              let sort = WorkSortOrder(rawValue: raw) else { return .addedRecently }
        return Self.currentSort(sort)
    }

    func setSelectedSort(_ sort: WorkSortOrder, for library: MediaLibraryKind) {
        defaults.set(Self.currentSort(sort).rawValue, forKey: Self.sortKey(library))
    }

    private static func currentSort(_ sort: WorkSortOrder) -> WorkSortOrder {
        // Compatibility with an earlier saved sort value; the picker no longer offers it.
        sort.rawValue == "rjCode" ? .custom : sort
    }

    func hasCustomOrder(for library: MediaLibraryKind) -> Bool {
        defaults.object(forKey: Self.customKey(library)) != nil
    }

    private func savedIDs(for library: MediaLibraryKind) -> [Int64] {
        (defaults.stringArray(forKey: Self.customKey(library)) ?? []).compactMap(Int64.init)
    }

    private func unique(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { $0 > 0 && seen.insert($0).inserted }
    }

    /// Pass the complete library, never a search/creator/tag subset. On first
    /// use its order becomes the seed. Later additions append at the end in the
    /// supplied stable order, and removed IDs disappear without reordering survivors.
    func resolvedOrder(allIDs: [Int64], for library: MediaLibraryKind) -> [Int64] {
        let complete = unique(allIDs)
        let available = Set(complete)
        let existing = unique(savedIDs(for: library)).filter { available.contains($0) }
        let known = Set(existing)
        return existing + complete.filter { !known.contains($0) }
    }

    @discardableResult
    func reconcile(allIDs: [Int64], for library: MediaLibraryKind) -> [Int64] {
        let order = resolvedOrder(allIDs: allIDs, for: library)
        let encoded = order.map(String.init)
        if defaults.stringArray(forKey: Self.customKey(library)) != encoded {
            defaults.set(encoded, forKey: Self.customKey(library))
        }
        return order
    }

    /// Replaces only the original slots occupied by the visible subset. An old
    /// drag snapshot, duplicate/foreign ID or incomplete permutation is rejected.
    /// No write occurs until every check succeeds.
    @discardableResult
    func reordered(_ orderedIDs: [Int64], visibleIDs: [Int64], allIDs: [Int64],
                   for library: MediaLibraryKind) -> [Int64]? {
        guard selectedSort(for: library) == .custom,
              !visibleIDs.isEmpty, unique(visibleIDs) == visibleIDs,
              unique(orderedIDs) == orderedIDs, Set(orderedIDs) == Set(visibleIDs),
              unique(allIDs) == allIDs else { return nil }
        let subset = Set(visibleIDs)
        guard savedIDs(for: library) == allIDs,
              subset.isSubset(of: Set(allIDs)), allIDs.filter({ subset.contains($0) }) == visibleIDs else { return nil }
        var replacements = orderedIDs.makeIterator()
        let result = allIDs.map { subset.contains($0) ? replacements.next()! : $0 }
        guard result != allIDs else { return nil }
        defaults.set(result.map(String.init), forKey: Self.customKey(library))
        return result
    }
}
