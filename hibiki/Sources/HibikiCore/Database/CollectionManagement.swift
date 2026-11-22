import Foundation

public struct NamedCollection: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
}

public enum CollectionKind: Sendable {
    case playlists, clips, favorites

    public var defaultID: Int64 { self == .clips ? 2 : 1 }
    fileprivate var table: String { self == .favorites ? "favorite_group" : "playlist_group" }
    fileprivate var condition: String {
        switch self {
        case .playlists: return "is_clips = 0"
        case .clips: return "is_clips = 1"
        case .favorites: return "1 = 1"
        }
    }
}

public enum GroupEditingError: LocalizedError {
    case duplicateName, protectedGroup, staleGroups
    public var errorDescription: String? {
        switch self {
        case .duplicateName: return InterfaceLocalization.text("已经有同名分类，请换一个名称。")
        case .protectedGroup: return InterfaceLocalization.text("默认分类用于接收其他分类的内容，可改名和排序。")
        case .staleGroups: return InterfaceLocalization.text("分类已变化，请重新选择。")
        }
    }
}

extension PlaylistRepository {
    public func collections(_ kind: CollectionKind) throws -> [NamedCollection] {
        try db.query("SELECT id, name FROM \(kind.table) WHERE \(kind.condition) ORDER BY sort_order, id").map {
            NamedCollection(id: $0.int64("id")!, name: $0.string("name")!)
        }
    }

    @discardableResult
    public func createCollection(_ kind: CollectionKind, name: String) throws -> Int64 {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PlaylistCollectionError.blankName }
        return try db.transaction {
            if try collections(kind).contains(where: { $0.name == cleaned }) { throw GroupEditingError.duplicateName }
            if kind != .favorites { return try createGroup(name: cleaned, isClips: kind == .clips) }
            try db.execute("""
                INSERT INTO favorite_group (name, sort_order)
                SELECT ?, COALESCE(MAX(sort_order), -1) + 1 FROM favorite_group
                """, [.text(cleaned)])
            return db.lastInsertRowID
        }
    }

    public func renameCollection(_ kind: CollectionKind, id: Int64, name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PlaylistCollectionError.blankName }
        try db.transaction {
            let current = try collections(kind)
            guard current.contains(where: { $0.id == id }) else { throw GroupEditingError.staleGroups }
            guard !current.contains(where: { $0.id != id && $0.name == cleaned }) else { throw GroupEditingError.duplicateName }
            try db.execute("UPDATE \(kind.table) SET name = ? WHERE id = ? AND \(kind.condition)", [.text(cleaned), .integer(id)])
        }
    }

    public func orderCollections(_ kind: CollectionKind, ids: [Int64]) throws {
        try db.transaction {
            let current = try collections(kind).map(\.id)
            guard ids.count == current.count, Set(ids) == Set(current) else { throw GroupEditingError.staleGroups }
            for (order, id) in ids.enumerated() {
                try db.execute("UPDATE \(kind.table) SET sort_order = ? WHERE id = ?", [.integer(order), .integer(id)])
            }
        }
    }

    /// 将被删分类的内容转入默认分类，保留独立摘选文件、曲目和收藏作品。
    public func deleteCollection(_ kind: CollectionKind, id: Int64) throws {
        guard id != kind.defaultID else { throw GroupEditingError.protectedGroup }
        try db.transaction {
            guard try collections(kind).contains(where: { $0.id == id }) else { throw GroupEditingError.staleGroups }
            let source = SQLValue.integer(id)
            let target = SQLValue.integer(kind.defaultID)
            switch kind {
            case .favorites:
                try db.execute("""
                    INSERT INTO favorite_membership (work_id, group_id)
                    SELECT work_id, ? FROM favorite_membership WHERE group_id = ?
                    ON CONFLICT (work_id, group_id) DO NOTHING
                    """, [target, source])
            case .playlists, .clips:
                if kind == .playlists {
                    // An audio track and a video attachment can share the same numeric ID.
                    if db.userVersion >= 23 {
                        try db.execute("""
                            DELETE FROM playlist_entry WHERE group_id = ? AND attachment_id IN
                                (SELECT attachment_id FROM playlist_entry WHERE group_id = ?)
                            """, [source, target])
                    }
                    try db.execute("""
                        DELETE FROM playlist_entry WHERE group_id = ? AND track_id IN
                            (SELECT track_id FROM playlist_entry WHERE group_id = ?)
                        """, [source, target])
                }
                try db.execute("UPDATE playlist_entry SET group_id = ? WHERE group_id = ?", [target, source])
            }
            try db.execute("DELETE FROM \(kind.table) WHERE id = ? AND \(kind.condition)", [source])
        }
    }

    public func favoriteMemberships() throws -> [Int64: Set<Int64>] {
        var result: [Int64: Set<Int64>] = [:]
        for row in try db.query("SELECT work_id, group_id FROM favorite_membership") {
            result[row.int64("work_id")!, default: []].insert(row.int64("group_id")!)
        }
        return result
    }

    public func setFavoriteGroups(workID: Int64, groupIDs: Set<Int64>) throws {
        try db.transaction {
            guard try db.queryInt("SELECT 1 FROM work WHERE id = ?", [.integer(workID)]) == 1 else {
                throw LibraryEditingError.missingWork
            }
            let available = Set(try collections(.favorites).map(\.id))
            guard groupIDs.isSubset(of: available) else { throw GroupEditingError.staleGroups }
            try db.execute("DELETE FROM favorite_membership WHERE work_id = ?", [.integer(workID)])
            for id in groupIDs {
                try db.execute("INSERT INTO favorite_membership (work_id, group_id) VALUES (?, ?)", [.integer(workID), .integer(id)])
            }
            try db.execute("UPDATE work SET favorite = ? WHERE id = ?", [.integer(!groupIDs.isEmpty), .integer(workID)])
        }
    }
}
