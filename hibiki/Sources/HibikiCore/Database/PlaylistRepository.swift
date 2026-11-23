import Foundation

public struct SavedPlaylistGroup: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let isClips: Bool
}

public struct SavedPlaylistEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let groupID: Int64
    public let attachmentID: Int64?
    public let trackID: Int64?
    public var wholeMediaID: WorkMediaID? {
        guard !isClip else { return nil }
        if let attachmentID { return .attachment(attachmentID) }
        return trackID.map(WorkMediaID.track)
    }
    public let workID: Int64?
    public let title: String
    public let workTitle: String
    public let startMS: Int?
    public let endMS: Int?
    public let clipFilename: String?
    public let mergedMS: Int?
    public let createdAt: Date
    public var isClip: Bool { clipFilename != nil }
    public var isMerged: Bool { mergedMS != nil }
    public var clipDurationMS: Int? {
        guard isClip else { return nil }
        if let mergedMS { return mergedMS > 0 ? mergedMS : nil }
        guard let startMS, let endMS, startMS >= 0, endMS > startMS else { return nil }
        return endMS - startMS
    }
}

public enum PlaylistCollectionError: LocalizedError {
    case blankName, invalidGroup, invalidSelection, staleEntries, duplicateEntry

    public var errorDescription: String? {
        switch self {
        case .blankName: return InterfaceLocalization.text("请输入名称。")
        case .invalidGroup: return InterfaceLocalization.text("请选择对应类型的收藏夹。")
        case .invalidSelection: return InterfaceLocalization.text("请至少选择两段已保存的摘选。")
        case .staleEntries: return InterfaceLocalization.text("列表内容已变化，请重新调整。")
        case .duplicateEntry: return InterfaceLocalization.text("目标分类中已存在这首曲目或视频。")
        }
    }
}

public final class PlaylistRepository {
    let db: SQLiteDatabase

    public init(database: SQLiteDatabase) { db = database }

    public func groups() throws -> [SavedPlaylistGroup] {
        try db.query("SELECT * FROM playlist_group ORDER BY sort_order, id").map { row in
            SavedPlaylistGroup(id: row.int64("id")!, name: row.string("name")!, isClips: row.bool("is_clips"))
        }
    }

    @discardableResult
    public func createGroup(name: String, isClips: Bool) throws -> Int64 {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlaylistCollectionError.blankName }
        let args: [SQLValue] = [.text(name), .integer(isClips)]
        try db.execute("""
            INSERT INTO playlist_group (name, is_clips, sort_order)
            VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM playlist_group WHERE is_clips = ?))
            ON CONFLICT(is_clips, name) DO NOTHING
            """, args + [.integer(isClips)])
        guard let id = try db.query("SELECT id FROM playlist_group WHERE name = ? AND is_clips = ?", args)
            .first?.int64("id") else { throw PlaylistCollectionError.invalidGroup }
        return id
    }

    private func target(_ id: Int64?, isClips: Bool) throws -> SQLValue {
        let value = SQLValue.integer(id ?? (isClips ? 2 : 1))
        guard try db.queryInt("SELECT 1 FROM playlist_group WHERE id = ? AND is_clips = ?",
                              [value, .integer(isClips)]) == 1 else { throw PlaylistCollectionError.invalidGroup }
        return value
    }

    public func entries() throws -> [SavedPlaylistEntry] {
        let version = db.userVersion
        let trackTitle = version >= 21 ? "COALESCE(t.title_override, e.title)" : "e.title"
        let attachmentJoin = version >= 23 ? "LEFT JOIN work_attachment v ON v.id = e.attachment_id" : ""
        let sourceWorkID = version >= 23 ? "COALESCE(t.work_id, v.work_id)" : "t.work_id"
        let ordering = version >= 26 ? "e.group_id, e.sort_order, e.id" : "e.id"
        return try db.query("""
            SELECT e.*, COALESCE(\(sourceWorkID), e.cover_work_id) AS work_id,
                   CASE WHEN e.clip_filename IS NULL THEN \(trackTitle) ELSE e.title END AS display_title,
                   COALESCE(\(LibraryRepository.displayedWorkTitleSQL(version: version)), e.work_title) AS display_work_title
              FROM playlist_entry e
              LEFT JOIN track t ON t.id = e.track_id
              \(attachmentJoin)
              LEFT JOIN work w ON w.id = \(sourceWorkID)
             ORDER BY \(ordering)
            """).map { row in
            SavedPlaylistEntry(
                id: row.int64("id")!, groupID: row.int64("group_id")!,
                attachmentID: row.int64("attachment_id"), trackID: row.int64("track_id"),
                workID: row.int64("work_id"), title: row.string("display_title")!, workTitle: row.string("display_work_title")!,
                startMS: row.int("start_ms"), endMS: row.int("end_ms"),
                clipFilename: row.string("clip_filename"), mergedMS: row.int("merged_ms"), createdAt: row.date("created_at")!
            )
        }
    }

    public func addWholeTrack(trackID: Int64, title: String, workTitle: String, groupID: Int64? = nil) throws {
        let group = try target(groupID, isClips: false)
        try db.execute("""
            INSERT INTO playlist_entry (group_id, track_id, title, work_title, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(group_id, track_id) WHERE clip_filename IS NULL DO NOTHING
            """, [group, .integer(trackID), .text(title), .text(workTitle), SQLValue(Date())])
    }

    public func addVideo(attachmentID: Int64, title: String, workTitle: String, groupID: Int64? = nil) throws {
        let group = try target(groupID, isClips: false)
        guard try db.queryInt("SELECT 1 FROM work_attachment WHERE id = ? AND kind = 'video'", [.integer(attachmentID)]) == 1 else {
            throw LibraryEditingError.staleTrackOrder
        }
        try db.execute("""
            INSERT INTO playlist_entry (group_id, attachment_id, title, work_title, created_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(group_id, attachment_id) WHERE attachment_id IS NOT NULL DO NOTHING
            """, [group, .integer(attachmentID), .text(title), .text(workTitle), SQLValue(Date())])
    }

    /// 返回 false 表示该组已有同一范围的摘选，调用方丢弃本次导出的副本。
    @discardableResult
    public func addClip(trackID: Int64, title: String, workTitle: String, startMS: Int,
                        endMS: Int, filename: String, groupID: Int64? = nil,
                        subtitles: ClipSubtitleSnapshot? = nil) throws -> Bool {
        let group = try target(groupID, isClips: true)
        return try db.transaction {
            let inserted = try db.execute("""
            INSERT INTO playlist_entry (group_id, track_id, title, work_title, start_ms, end_ms, clip_filename, created_at)
            SELECT ?, ?, ?, ?, ?, ?, ?, ?
            WHERE NOT EXISTS (SELECT 1 FROM playlist_entry WHERE group_id = ? AND track_id = ?
                              AND start_ms = ? AND end_ms = ? AND clip_filename IS NOT NULL)
            """, [group, .integer(trackID), .text(title), .text(workTitle), .integer(startMS),
                  .integer(endMS), .text(filename), SQLValue(Date()), group, .integer(trackID),
                  .integer(startMS), .integer(endMS)]) == 1
            if inserted, let subtitles {
                try saveClipSubtitles(entryID: db.lastInsertRowID, snapshot: subtitles)
            }
            return inserted
        }
    }

    public func addMerged(title: String, workTitle: String, coverWorkID: Int64?, durationMS: Int,
                          filename: String, groupID: Int64, subtitles: ClipSubtitleSnapshot? = nil) throws {
        let group = try target(groupID, isClips: true)
        try db.transaction {
            try db.execute("""
            INSERT INTO playlist_entry (group_id, title, work_title, merged_ms, clip_filename, cover_work_id, created_at)
            VALUES (?, ?, ?, ?, ?, (SELECT id FROM work WHERE id = ?), ?)
            """, [group, .text(title), .text(workTitle), .integer(durationMS), .text(filename),
                  coverWorkID.map(SQLValue.integer) ?? .null, SQLValue(Date())])
            if let subtitles {
                try saveClipSubtitles(entryID: db.lastInsertRowID, snapshot: subtitles)
            }
        }
    }

    /// nil means an older clip has no snapshot yet; an empty snapshot means the
    /// clip was deliberately saved with no corresponding timed subtitles.
    public func clipSubtitles(entryID: Int64) throws -> ClipSubtitleSnapshot? {
        guard db.userVersion >= 22 else { return nil }
        guard let json = try db.query("SELECT snapshot_json FROM playlist_clip_subtitle WHERE entry_id = ?",
                                      [.integer(entryID)]).first?.string("snapshot_json") else { return nil }
        return try JSONDecoder().decode(ClipSubtitleSnapshot.self, from: Data(json.utf8))
    }

    /// Captured subtitles are immutable with respect to the original track.
    /// The optional insert-only form lets legacy backfill preserve an existing snapshot.
    public func saveClipSubtitles(entryID: Int64, snapshot: ClipSubtitleSnapshot, onlyIfMissing: Bool = false) throws {
        guard try db.queryInt("SELECT 1 FROM playlist_entry WHERE id = ? AND clip_filename IS NOT NULL",
                              [.integer(entryID)]) == 1 else { throw PlaylistCollectionError.invalidSelection }
        let data = try JSONEncoder().encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)
        let conflict = onlyIfMissing ? "DO NOTHING" : "DO UPDATE SET snapshot_json = excluded.snapshot_json"
        try db.execute("INSERT INTO playlist_clip_subtitle (entry_id, snapshot_json) VALUES (?, ?) ON CONFLICT(entry_id) \(conflict)",
                       [.integer(entryID), .text(json)])
    }

    public func remove(id: Int64) throws {
        try db.execute("DELETE FROM playlist_entry WHERE id = ?", [.integer(id)])
    }
}
