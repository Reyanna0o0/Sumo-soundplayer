import Foundation

/// Portable drag content. The UI owns transfer/loading and gesture lifetimes;
/// Core validates the work and computes exactly the move shown by the marker.
public struct WorkReorderPayload: Codable, Equatable, Sendable {
    public enum Content: Codable, Equatable, Sendable {
        case item(WorkMediaID), group(String)
    }
    public let workID: Int64
    public let content: Content
    public init(workID: Int64, content: Content) {
        self.workID = workID; self.content = content
    }
}

public enum WorkDropDestination: Codable, Equatable, Sendable {
    case item(category: String, neighbor: WorkMediaID, after: Bool)
    case groupStart(String)
    case groupEnd(String)
    case groupEdge(category: String, after: Bool)
}

/// Full category order, including hidden empty built-ins. An asynchronously
/// loaded drag must not overwrite changes made after its insertion marker.
public struct WorkReorderSnapshot: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        public let category: WorkCategory
        public let itemIDs: [WorkMediaID]
        public init(category: WorkCategory, itemIDs: [WorkMediaID]) {
            self.category = category; self.itemIDs = itemIDs
        }
    }
    public let workID: Int64
    public let groups: [Group]
    public init(workID: Int64, groups: [Group]) { self.workID = workID; self.groups = groups }
    public init(workID: Int64, sections: [WorkMediaSection]) {
        self.init(workID: workID, groups: sections.map { Group(category: $0.category, itemIDs: $0.items.map(\.id)) })
    }
}

public enum WorkReorderPlan: Equatable, Sendable {
    case unchanged
    case item(id: WorkMediaID, category: String, orderedIDs: [WorkMediaID])
    case groups([String])
}

public enum WorkReorderPlanner {
    public static func plan(payload: WorkReorderPayload, to destination: WorkDropDestination,
                            in snapshot: WorkReorderSnapshot) throws -> WorkReorderPlan {
        let keys = snapshot.groups.map { $0.category.key }
        let allItems = snapshot.groups.flatMap(\.itemIDs)
        guard payload.workID > 0, payload.workID == snapshot.workID,
              !keys.isEmpty, keys.allSatisfy({ !$0.isEmpty }), Set(keys).count == keys.count,
              Set(allItems).count == allItems.count else { throw LibraryEditingError.staleTrackOrder }

        let category: String
        switch destination {
        case .item(let key, _, _), .groupEdge(let key, _): category = key
        case .groupStart(let key), .groupEnd(let key): category = key
        }
        guard let target = snapshot.groups.first(where: { $0.category.key == category }) else {
            throw LibraryEditingError.staleTrackOrder
        }
        // An item hover is anchored to that exact row, even for a whole-group
        // drag whose visible marker belongs at the containing group's end.
        if case .item(_, let neighbor, _) = destination, !target.itemIDs.contains(neighbor) {
            throw LibraryEditingError.staleTrackOrder
        }

        switch payload.content {
        case .item(let item):
            guard allItems.contains(item) else { throw LibraryEditingError.staleTrackOrder }
            if case .groupEdge = destination { throw LibraryEditingError.staleTrackOrder }
            if case .item(_, let neighbor, _) = destination, item == neighbor { return .unchanged }
            var ids = target.itemIDs.filter { $0 != item }
            let insertion: Int
            switch destination {
            case .groupStart: insertion = 0
            case .groupEnd: insertion = ids.count
            case .item(_, let neighbor, let after):
                guard let index = ids.firstIndex(of: neighbor) else { throw LibraryEditingError.staleTrackOrder }
                insertion = index + (after ? 1 : 0)
            case .groupEdge: throw LibraryEditingError.staleTrackOrder
            }
            ids.insert(item, at: insertion)
            return ids == target.itemIDs ? .unchanged : .item(id: item, category: category, orderedIDs: ids)

        case .group(let moving):
            guard keys.contains(moving) else { throw LibraryEditingError.staleTrackOrder }
            if moving == category { return .unchanged }
            let after: Bool
            switch destination {
            case .groupEdge(_, let side): after = side
            case .groupStart: after = false
            case .groupEnd, .item: after = true
            }
            var result = keys.filter { $0 != moving }
            guard let targetIndex = result.firstIndex(of: category) else { throw LibraryEditingError.staleTrackOrder }
            result.insert(moving, at: targetIndex + (after ? 1 : 0))
            return result == keys ? .unchanged : .groups(result)
        }
    }
}
