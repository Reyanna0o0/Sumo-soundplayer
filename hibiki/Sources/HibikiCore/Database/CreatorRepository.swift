import Foundation

public enum CreatorEditingError: LocalizedError, Equatable {
    case blankName, missingCreator, invalidCover, notPersonalWork

    public var errorDescription: String? {
        switch self {
        case .blankName: return InterfaceLocalization.text("请输入创作者名字。")
        case .missingCreator: return InterfaceLocalization.text("这个创作者已不存在，请重新选择。")
        case .invalidCover: return InterfaceLocalization.text("请选择用作创作者封面的图片。")
        case .notPersonalWork: return InterfaceLocalization.text("请在个人音声作品中编辑创作者。")
        }
    }
}

extension LibraryRepository {
    public func creators() throws -> [CreatorRecord] {
        try db.query("SELECT * FROM creator ORDER BY name COLLATE NOCASE, id").map(mapCreatorRow)
    }

    public func creator(id: Int64) throws -> CreatorRecord? {
        try db.query("SELECT * FROM creator WHERE id = ?", [.integer(id)]).first.map(mapCreatorRow)
    }

    /// Names are display metadata. Equal names do not merge independent profiles.
    @discardableResult
    public func saveCreator(_ creator: CreatorRecord) throws -> Int64 {
        let name = creator.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CreatorEditingError.blankName }
        guard creator.id >= 0 else { throw CreatorEditingError.missingCreator }
        for path in [creator.avatarAssetPath, creator.coverAssetPath].compactMap({ $0 }) {
            guard !path.contains("\0"), LibraryPathResolver.assetPath(relative: path, assetsRoot: "/assets") != nil else {
                throw LibraryEditingError.invalidAssetPath
            }
        }
        if creator.coverMode == .image, creator.coverAssetPath == nil { throw CreatorEditingError.invalidCover }
        return try db.transaction {
            let fields: [SQLValue] = [.text(name), .optional(creator.avatarAssetPath),
                .text(creator.coverMode.rawValue), .optional(creator.coverAssetPath), .text(creator.note), SQLValue(Date())]
            if creator.id > 0 {
                guard try self.creator(id: creator.id) != nil else { throw CreatorEditingError.missingCreator }
                try db.execute("""
                    UPDATE creator SET name = ?, avatar_asset_path = ?, cover_mode = ?,
                        cover_asset_path = ?, note = ?, updated_at = ? WHERE id = ?
                    """, fields + [.integer(creator.id)])
                return creator.id
            }
            try db.execute("""
                INSERT INTO creator(name, avatar_asset_path, cover_mode, cover_asset_path, note, updated_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, fields + [SQLValue(creator.createdAt)])
            return db.lastInsertRowID
        }
    }

    public func recentCreators(limit: Int = 12) throws -> [CreatorRecord] {
        guard limit > 0 else { return [] }
        return try db.query("""
            SELECT c.* FROM creator c
            JOIN work w ON w.creator_id = c.id AND w.library_kind = 'personal'
            WHERE w.last_played_at IS NOT NULL
            GROUP BY c.id ORDER BY MAX(w.last_played_at) DESC, c.id LIMIT ?
            """, [.integer(limit)]).map(mapCreatorRow)
    }

    /// Updates user-owned metadata only; media, subtitles, collections and history
    /// retain their identities and contents. Rescans cannot replace these fields.
    @discardableResult
    public func savePersonalWorkMetadata(workID: Int64, title: String, creatorID: Int64?,
                                         playerCoverMode: PlayerCoverMode? = nil) throws -> Int64? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryEditingError.blankTitle }
        return try db.transaction {
            guard let work = try work(id: workID) else { throw LibraryEditingError.missingWork }
            guard work.libraryKind == .personal else { throw CreatorEditingError.notPersonalWork }
            try validateCreatorAssignment(libraryKind: .personal, creatorID: creatorID)
            try updatePlayerCoverMode(playerCoverMode, for: work)
            let renamed = title != work.title
            var renamedTrackID: Int64?
            if renamed, work.trackCount == 1, db.userVersion >= 21 {
                renamedTrackID = try db.query("SELECT id FROM track WHERE work_id = ? AND is_video = 0",
                    [.integer(workID)]).first?.int64("id")
                try db.execute("UPDATE track SET title_override = ? WHERE work_id = ? AND is_video = 0",
                    [.text(title), .integer(workID)])
            }
            try db.execute("UPDATE work SET title_override = COALESCE(?, title_override), creator_id = ?, updated_at = ? WHERE id = ?",
                [renamed ? .text(title) : .null, creatorID.map(SQLValue.integer) ?? .null, SQLValue(Date()), .integer(workID)])
            return renamedTrackID
        }
    }

    func validateCreatorAssignment(libraryKind: MediaLibraryKind, creatorID: Int64?) throws {
        guard let creatorID else { return }
        guard libraryKind == .personal else { throw CreatorEditingError.notPersonalWork }
        guard creatorID > 0, try creator(id: creatorID) != nil else { throw CreatorEditingError.missingCreator }
    }

    private func mapCreatorRow(_ row: SQLRow) -> CreatorRecord {
        CreatorRecord(id: row.int64("id")!, name: row.string("name")!,
            avatarAssetPath: row.string("avatar_asset_path"),
            coverMode: CreatorCoverMode(rawValue: row.string("cover_mode") ?? "none") ?? .none,
            coverAssetPath: row.string("cover_asset_path"), note: row.string("note") ?? "",
            createdAt: row.date("created_at")!, updatedAt: row.date("updated_at")!)
    }
}
