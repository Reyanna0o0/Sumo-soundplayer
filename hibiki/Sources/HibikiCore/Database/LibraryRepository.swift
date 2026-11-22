import Foundation

/// 媒体库的数据库读写（source / work / track / app_setting）。
///
/// 所有方法都不做 UI 相关的事，只管存与取；出错直接 throw，
/// 由上层决定怎么提示用户。
public final class LibraryRepository {

    let db: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.db = database
    }

    /// 建库/升级到最新版本
    @discardableResult
    public func prepare() throws -> Int {
        try db.migrate(Schema.migrations)
    }

    // MARK: - 存储源

    @discardableResult
    public func saveSource(_ source: LibrarySource) throws -> Int64 {
        if source.id > 0 {
            try db.execute(
                """
                UPDATE source
                   SET name = ?, type = ?, root_path = ?, bookmark = ?, enabled = ?, grouping = ?
                 WHERE id = ?
                """,
                [
                    .text(source.name),
                    .text(source.type.rawValue),
                    .optional(source.rootPath),
                    .optional(source.bookmark),
                    .integer(source.enabled),
                    .text(source.grouping.rawValue),
                    .integer(source.id)
                ]
            )
            return source.id
        }
        try db.execute(
            """
            INSERT INTO source (name, type, root_path, bookmark, enabled, created_at, grouping)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(source.name),
                .text(source.type.rawValue),
                .optional(source.rootPath),
                .optional(source.bookmark),
                .integer(source.enabled),
                SQLValue(source.createdAt),
                .text(source.grouping.rawValue)
            ]
        )
        return db.lastInsertRowID
    }

    public func sources(includeDisabled: Bool = false) throws -> [LibrarySource] {
        let sql = includeDisabled
            ? "SELECT * FROM source ORDER BY created_at"
            : "SELECT * FROM source WHERE enabled = 1 ORDER BY created_at"
        return try db.query(sql).map { row in
            LibrarySource(
                id: row.int64("id") ?? 0,
                name: row.string("name") ?? "未命名",
                type: SourceType(rawValue: row.string("type") ?? "local") ?? .local,
                rootPath: row.string("root_path"),
                bookmark: row.data("bookmark"),
                enabled: row.bool("enabled"),
                createdAt: row.date("created_at") ?? Date(),
                grouping: ScanOptions.Grouping(rawValue: row.string("grouping") ?? "automatic") ?? .automatic
            )
        }
    }

    public func deleteSource(id: Int64) throws {
        try db.execute("DELETE FROM source WHERE id = ?", [.integer(id)])
    }

    // MARK: - 作品

    /// 作品在数据库里的"位置键"。
    ///
    /// 统一入口很重要：入库和后续清理必须用同一个键，
    /// 否则会出现"刚导入就被清理掉"这种诡异问题。
    /// - 正常作品：相对存储源的路径
    /// - 整个源根目录就是作品：`"."`
    /// - 老调用方只给了绝对路径：退回用绝对路径
    public static func storageKey(relativePath: String, absolutePath: String) -> String {
        // 相对路径非空：正常作品
        if !relativePath.isEmpty { return relativePath }
        // 相对路径为空 = 整个存储源根目录就是一个作品
        // 用 "." 而不是绝对路径：绝对路径在重装/恢复后可能失效
        return "."
    }

    /// 插入或更新一个作品，返回其 id。
    ///
    /// 去重键是 `(source_id, folder_path)`：同一个目录重复扫描不会产生重复作品。
    @discardableResult
    public func upsertWork(_ work: WorkRecord) throws -> Int64 {
        let now = Date()
        // 去重键：优先用相对路径；老调用方只给了绝对路径时退回用它
        let relKey = work.folderRelativePath.isEmpty ? work.folderPath : work.folderRelativePath
        var work = work
        work.folderRelativePath = relKey
        if let existingID = try workID(sourceID: work.sourceID, folderRelativePath: relKey) {
            try db.execute(
                """
                UPDATE work
                   SET rj_code = ?, title = ?, circle_name = ?, seiyuu_name = ?,
                       cover_path = ?, script_path = ?, folder_rel = ?, updated_at = ?
                 WHERE id = ?
                """,
                [
                    .optional(work.rjCode),
                    .text(work.title),
                    .optional(work.circleName),
                    .optional(work.seiyuuName),
                    .optional(work.coverPath),
                    .optional(work.scriptPath),
                    .text(work.folderRelativePath),
                    SQLValue(now),
                    .integer(existingID)
                ]
            )
            return existingID
        }

        let hasLibraries = db.userVersion >= 17
        if hasLibraries {
            try validateCreatorAssignment(libraryKind: work.libraryKind, creatorID: work.creatorID)
        } else if work.libraryKind != .collection || work.creatorID != nil {
            throw LibraryEditingError.unavailable
        }
        let libraryColumns = hasLibraries ? ", library_kind, creator_id" : ""
        let libraryValues = hasLibraries ? ", ?, ?" : ""
        let libraryParams: [SQLValue] = hasLibraries
            ? [.text(work.libraryKind.rawValue), work.creatorID.map(SQLValue.integer) ?? .null] : []
        try db.execute(
            """
            INSERT INTO work (
                rj_code, title, circle_name, seiyuu_name, cover_path,
                folder_path, folder_rel, source_id, created_at, updated_at, script_path\(libraryColumns)
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?\(libraryValues))
            """,
            [
                .optional(work.rjCode),
                .text(work.title),
                .optional(work.circleName),
                .optional(work.seiyuuName),
                .optional(work.coverPath),
                .text(work.folderPath),
                .text(work.folderRelativePath),
                .integer(work.sourceID),
                SQLValue(work.createdAt),
                SQLValue(now),
                .optional(work.scriptPath)
            ] + libraryParams
        )
        return db.lastInsertRowID
    }

    public func workID(sourceID: Int64, folderRelativePath: String) throws -> Int64? {
        let rows = try db.query(
            "SELECT id FROM work WHERE source_id = ? AND folder_rel = ?",
            [.integer(sourceID), .text(folderRelativePath)]
        )
        if let id = rows.first?.int64("id") { return id }
        // 兼容旧数据（v3 之前只存了绝对路径）
        let legacy = try db.query(
            "SELECT id FROM work WHERE source_id = ? AND folder_path = ?",
            [.integer(sourceID), .text(folderRelativePath)]
        )
        return legacy.first?.int64("id")
    }

    /// 作品列表（带曲目数与总时长聚合）
    public func works(
        sourceID: Int64? = nil,
        filter: WorkFilter = .all,
        sort: WorkSortOrder = .addedRecently,
        searchText: String? = nil,
        limit: Int? = nil,
        libraryKind: MediaLibraryKind? = nil,
        creatorID: Int64? = nil
    ) throws -> [WorkRecord] {
        let version = db.userVersion
        let rj = version >= 13 ? "COALESCE(w.rj_code_override, w.rj_code)" : "w.rj_code"
        var conditions: [String] = []
        var params: [SQLValue] = []

        if let sourceID {
            conditions.append("w.source_id = ?")
            params.append(.integer(sourceID))
        }

        if let libraryKind {
            if version >= 17 {
                conditions.append("w.library_kind = ?")
                params.append(.text(libraryKind.rawValue))
            } else if libraryKind != .collection {
                conditions.append("0")
            }
        }
        if let creatorID {
            if version >= 17 {
                conditions.append("w.creator_id = ?")
                params.append(.integer(creatorID))
            } else { conditions.append("0") }
        }

        switch filter {
        case .all:
            break
        case .favorite:
            conditions.append("w.favorite = 1")
        case .listening:
            conditions.append("w.last_played_track_id IS NOT NULL AND w.listened = 0")
        case .unlistened:
            conditions.append("w.last_played_track_id IS NULL")
        case .listened:
            conditions.append("w.listened = 1")
        }

        if let searchText, !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let creatorSearch = version >= 17
                ? " OR EXISTS (SELECT 1 FROM creator c WHERE c.id = w.creator_id AND c.name LIKE ?)" : ""
            conditions.append("(display_work_title LIKE ? OR COALESCE(w.seiyuu_names_override, w.seiyuu_name) LIKE ? OR COALESCE(w.circle_name_override, w.circle_name) LIKE ? OR \(rj) LIKE ?\(creatorSearch))")
            let pattern = "%\(searchText)%"
            params.append(contentsOf: [
                .text(pattern), .text(pattern), .text(pattern), .text(pattern)
            ])
            if version >= 17 { params.append(.text(pattern)) }
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        let orderClause: String
        switch sort {
        case .recentlyPlayed:
            orderClause = "ORDER BY (w.last_played_at IS NULL), w.last_played_at DESC"
        case .addedRecently:
            orderClause = "ORDER BY w.created_at DESC"
        case .title:
            orderClause = "ORDER BY display_work_title COLLATE NOCASE"
        case .custom:
            // The app applies its per-library saved ID order. This provides a
            // stable order for the initial seed and newly imported works.
            orderClause = "ORDER BY w.created_at DESC, w.id DESC"
        case .rjCode:
            orderClause = "ORDER BY COALESCE(\(rj), '') = '', \(rj)"
        }

        let limitClause = limit.map { "LIMIT \($0)" } ?? ""

        let sql = """
        \(workSummarySelect(version: version))
          \(whereClause)
          \(orderClause)
          \(limitClause)
        """

        return try db.query(sql, params).map(mapWorkRow)
    }

    public func work(id: Int64) throws -> WorkRecord? {
        try db.query(
            """
            \(workSummarySelect(version: db.userVersion)) WHERE w.id = ?
            """,
            [.integer(id)]
        ).first.map(mapWorkRow)
    }

    static func displayedWorkTitleSQL(version: Int) -> String {
        guard version >= 21 else { return version >= 10 ? "COALESCE(w.title_override, w.title)" : "w.title" }
        return """
            COALESCE(CASE WHEN w.library_kind = 'personal' THEN (
                SELECT CASE WHEN COUNT(*) = 1 THEN
                    COALESCE(a.title_override, NULLIF(a.title, ''), filename_stem(a.file_name)) END
                FROM track a WHERE a.work_id = w.id AND a.is_video = 0
            ) END, w.title_override, w.title)
            """
    }

    private func workSummarySelect(version: Int) -> String {
        let videoCount = version >= 13
            ? "(SELECT COUNT(*) FROM work_attachment a WHERE a.work_id = w.id AND a.kind = 'video')"
            : "(SELECT COUNT(*) FROM track t WHERE t.work_id = w.id AND t.is_video = 1)"
        return """
            SELECT w.*, \(Self.displayedWorkTitleSQL(version: version)) AS display_work_title, \(videoCount) AS video_count,
                   (SELECT COUNT(*) FROM track t WHERE t.work_id = w.id AND t.is_video = 0) AS track_count,
                   (SELECT COALESCE(SUM(t.duration_ms), 0) FROM track t WHERE t.work_id = w.id AND t.is_video = 0) AS total_duration
              FROM work w
            """
    }

    public func deleteWork(id: Int64) throws {
        try db.execute("DELETE FROM work WHERE id = ?", [.integer(id)])
    }

    /// 删除某个源下所有作品（重新扫描前清空）
    public func deleteWorks(sourceID: Int64) throws {
        try db.execute("DELETE FROM work WHERE source_id = ?", [.integer(sourceID)])
    }

    /// 删除源里"这次没扫到"的作品（增量同步用）
    @discardableResult
    public func deleteWorks(sourceID: Int64, notInFolderPaths paths: [String]) throws -> Int {
        let placeholders = paths.map { _ in "?" }.joined(separator: ",")
        var params: [SQLValue] = [.integer(sourceID)]
        params.append(contentsOf: paths.map { SQLValue.text($0) })
        let absent = "source_id = ?" + (paths.isEmpty ? "" : " AND folder_rel NOT IN (\(placeholders))")
        let removable = absent + " AND NOT EXISTS (SELECT 1 FROM work_attachment a WHERE a.work_id = work.id AND a.asset_relative_path IS NOT NULL) AND NOT EXISTS (SELECT 1 FROM track t WHERE t.work_id = work.id AND t.asset_relative_path IS NOT NULL)"
        return try db.transaction {
            let count = try db.queryInt("SELECT COUNT(*) FROM work WHERE \(removable)", params) ?? 0
            try db.execute("DELETE FROM work WHERE \(removable)", params)
            // 原目录消失时，独立添加的曲目保留，旧目录里的失效曲目照常清理。
            try db.execute("DELETE FROM track WHERE asset_relative_path IS NULL AND work_id IN (SELECT id FROM work WHERE \(absent))", params)
            return count
        }
    }

    // MARK: - 状态更新

    public func setFavorite(_ favorite: Bool, workID: Int64) throws {
        try db.execute("UPDATE work SET favorite = ? WHERE id = ?", [.integer(favorite), .integer(workID)])
    }

    public func setListened(_ listened: Bool, workID: Int64) throws {
        try db.execute("UPDATE work SET listened = ? WHERE id = ?", [.integer(listened), .integer(workID)])
    }

    public func setRating(_ rating: Int, workID: Int64) throws {
        let clamped = max(0, min(5, rating))
        try db.execute("UPDATE work SET rating = ? WHERE id = ?", [.integer(clamped), .integer(workID)])
    }

    /// 保存断点续播位置
    public func savePlaybackPosition(workID: Int64, trackID: Int64, positionMS: Int, countAsPlay: Bool = true) throws {
        try db.execute(
            """
            UPDATE work
               SET last_played_track_id = ?, last_played_position = ?,
                   play_count = play_count + ?, last_played_at = ?, updated_at = ?
             WHERE id = ?
            """,
            [.integer(trackID), .integer(positionMS), .integer(countAsPlay), SQLValue(Date()), SQLValue(Date()), .integer(workID)]
        )
    }

    // MARK: - 曲目

    /// 同一作品重扫时原位更新曲目，字幕版本、手动分组和顺序都挂在原有记录上。
    public func replaceTracks(workID: Int64, tracks candidates: [TrackRecord]) throws {
        try db.transaction {
            let hidden = db.userVersion >= 13 ? try excludedFiles(workID: workID, kind: "track") : []
            let tracks = candidates.filter { !hidden.contains($0.relativePath ?? $0.fileName) }
            let existing = try self.tracks(workID: workID).filter { $0.assetRelativePath == nil }
            let folderPath = try db.query("SELECT folder_path FROM work WHERE id = ?", [.integer(workID)])
                .first?.string("folder_path")
            let folderPrefix = folderPath.map { $0.hasSuffix("/") ? $0 : $0 + "/" }

            // 旧库有些嵌套曲目的相对路径只存了文件名，能从原目录还原时包含子目录。
            func relativeKey(_ track: TrackRecord) -> String? {
                if let folderPrefix, track.filePath.hasPrefix(folderPrefix) {
                    return String(track.filePath.dropFirst(folderPrefix.count))
                }
                return track.relativePath
            }

            let oldByPath = Dictionary(grouping: existing, by: \.filePath)
            let oldByRelative = Dictionary(grouping: existing, by: relativeKey)
            let newByRelative = Dictionary(grouping: tracks, by: relativeKey)
            let newPaths = Set(tracks.map(\.filePath))
            var obsolete = Set(existing.map(\.id))

            for (index, track) in tracks.enumerated() {
                var previous = oldByPath[track.filePath]?.first
                // 容器位置变了时，只有新旧两侧均唯一的相对路径才能沿用原编号。
                if previous == nil, let key = relativeKey(track), !key.isEmpty,
                   newByRelative[key]?.count == 1, let candidates = oldByRelative[key],
                   candidates.count == 1, !newPaths.contains(candidates[0].filePath) {
                    previous = candidates[0]
                }
                let previousID = previous.flatMap { obsolete.remove($0.id) }
                let params: [SQLValue] = [
                    previousID.map { .integer($0) } ?? .null,
                    .integer(workID),
                    .text(track.fileName),
                    .text(track.filePath),
                    .optional(track.relativePath),
                    .text(track.fileType),
                    .integer(track.isVideo),
                    .integer(index),
                    .optional(track.title),
                    .optional(track.durationMS),
                    track.fileSize.map { SQLValue.integer($0) } ?? .null,
                    track.fileMtime.map { SQLValue($0) } ?? .null,
                    SQLValue(track.createdAt),
                    .text(track.category.rawValue),
                    .text(track.relativePath ?? track.fileName),
                    .optional(track.categoryOverride),
                    .integer(index)
                ]
                try db.execute(
                    """
                    INSERT INTO track (
                        id, work_id, file_name, file_path, relative_path, file_type,
                        is_video, track_index, title, duration_ms, file_size, file_mtime,
                        created_at, category, file_rel, category_override, sort_order
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        file_name = excluded.file_name, file_path = excluded.file_path,
                        relative_path = excluded.relative_path, file_type = excluded.file_type,
                        is_video = excluded.is_video, track_index = excluded.track_index,
                        title = excluded.title, duration_ms = excluded.duration_ms,
                        file_size = excluded.file_size, file_mtime = excluded.file_mtime,
                        category = excluded.category, file_rel = excluded.file_rel
                    """,
                    params
                )
            }
            for id in obsolete {
                try db.execute("DELETE FROM track WHERE id = ?", [.integer(id)])
            }
        }
    }

    public func tracks(workID: Int64) throws -> [TrackRecord] {
        try db.query(
            "SELECT * FROM track WHERE work_id = ? ORDER BY sort_order, track_index",
            [.integer(workID)]
        ).map(mapTrackRow)
    }

    /// 用户资料与扫描资料分列，留空也视为明确的手动选择。
    public func updateWorkMetadata(workID: Int64, title: String? = nil, rjCode: String? = nil, circleName: String,
                                   seiyuuNames: [String], cover: WorkCoverUpdate = .unchanged,
                                   playerCoverMode: PlayerCoverMode? = nil) throws {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, title.isEmpty { throw LibraryEditingError.blankTitle }
        let rj = rjCode.map { input -> String in
            let value = input.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return !value.isEmpty && value.allSatisfy({ $0.isASCII && $0.isNumber }) ? "RJ" + value : value
        }
        if let rj, !rj.isEmpty, rj.range(of: #"^(?:RJ|BJ)[0-9]+$"#, options: .regularExpression) == nil {
            throw LibraryEditingError.invalidRJ
        }
        let names = seiyuuNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let encoded = String(decoding: try JSONEncoder().encode(names), as: UTF8.self)
        try db.transaction {
            guard let existing = try work(id: workID) else { throw LibraryEditingError.missingWork }
            try updatePlayerCoverMode(playerCoverMode, for: existing)
            let coverPath: String?
            switch cover {
            case .unchanged: coverPath = existing.coverAssetPath
            case .restoreOriginal: coverPath = nil
            case .replace(let relative):
                guard LibraryPathResolver.assetPath(relative: relative, assetsRoot: "/assets") != nil else {
                    throw LibraryEditingError.invalidAssetPath
                }
                coverPath = relative
            }
            try db.execute("""
                UPDATE work SET title_override = COALESCE(?, title_override), rj_code_override = COALESCE(?, rj_code_override), circle_name_override = ?,
                    seiyuu_names_override = ?, cover_asset_path = ?, updated_at = ? WHERE id = ?
                """, [.optional(title), .optional(rj == existing.rjCode || (rj == "" && existing.rjCode == nil) ? nil : rj), .text(circleName.trimmingCharacters(in: .whitespacesAndNewlines)),
                      .text(encoded), .optional(coverPath), SQLValue(Date()), .integer(workID)])
            if let title, title != existing.title {
                // Keep the latest name on independent clips even if their source is later removed.
                try db.execute("""
                    UPDATE playlist_entry SET work_title = ?
                    WHERE track_id IN (SELECT id FROM track WHERE work_id = ?)
                    """, [.text(title), .integer(workID)])
            }
        }
    }

    func updatePlayerCoverMode(_ mode: PlayerCoverMode?, for work: WorkRecord) throws {
        guard let mode, mode != work.playerCoverMode else { return }
        try db.execute("UPDATE work SET player_cover_mode = ? WHERE id = ?", [.text(mode.rawValue), .integer(work.id)])
    }

    public func updateWorkCover(workID: Int64, assetRelativePath: String?) throws {
        guard try work(id: workID) != nil else { throw LibraryEditingError.missingWork }
        if let assetRelativePath, LibraryPathResolver.assetPath(relative: assetRelativePath, assetsRoot: "/assets") == nil {
            throw LibraryEditingError.invalidAssetPath
        }
        try db.execute("UPDATE work SET cover_asset_path = ?, updated_at = ? WHERE id = ?",
                       [.optional(assetRelativePath), SQLValue(Date()), .integer(workID)])
    }

    /// 整批追加或整批回滚，不替换现有曲目、字幕、分组和顺序。
    public func appendOwnedTracks(workID: Int64, tracks: [TrackRecord]) throws {
        try db.transaction {
            guard try work(id: workID) != nil else { throw LibraryEditingError.missingWork }
            let old = try self.tracks(workID: workID)
            let nextOrder = db.userVersion >= 13 ? try nextMediaOrder(workID: workID) : (old.map(\.sortOrder).max() ?? -1) + 1
            let nextIndex = (old.map(\.trackIndex).max() ?? -1) + 1
            for (offset, track) in tracks.enumerated() {
                guard let relative = track.assetRelativePath,
                      LibraryPathResolver.assetPath(relative: relative, assetsRoot: "/assets") != nil else {
                    throw LibraryEditingError.invalidAssetPath
                }
                try db.execute("""
                    INSERT INTO track (work_id, file_name, file_path, file_type, is_video, track_index,
                        title, duration_ms, file_size, file_mtime, created_at, category, sort_order, asset_relative_path)
                    VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [
                        .integer(workID), .text(track.fileName), .text("app-asset:" + relative), .text(track.fileType),
                        .integer(nextIndex + offset), .optional(track.title), .optional(track.durationMS),
                        track.fileSize.map(SQLValue.integer) ?? .null, track.fileMtime.map { SQLValue($0) } ?? .null,
                        SQLValue(track.createdAt), .text(track.category.rawValue), .integer(nextOrder + offset), .text(relative)
                    ])
            }
        }
    }

    /// 批量更新曲目时长（导入后异步探测用）
    public func updateTrackDurations(_ durations: [(trackID: Int64, durationMS: Int?)]) throws {
        guard !durations.isEmpty else { return }
        try db.transaction {
            for item in durations {
                guard let ms = item.durationMS else { continue }
                try db.execute(
                    "UPDATE track SET duration_ms = ? WHERE id = ?",
                    [.integer(ms), .integer(item.trackID)]
                )
            }
        }
    }

    public func track(id: Int64) throws -> TrackRecord? {
        try db.query("SELECT * FROM track WHERE id = ?", [.integer(id)]).first.map(mapTrackRow)
    }

    /// 按分组显示曲目（内置分组 + 用户自定义分组，按顺序排列）
    public func tracksGrouped(workID: Int64) throws -> [(category: WorkCategory, tracks: [TrackRecord])] {
        let all = try tracks(workID: workID)
        let categories = try self.categories(workID: workID)
        let byKey = Dictionary(grouping: all) { $0.effectiveCategoryKey }

        var result: [(WorkCategory, [TrackRecord])] = []
        var emitted = Set<String>()

        for category in categories {
            let list = byKey[category.key] ?? []
            // 内置分组空了就藏起来（免得六个空分组占屏）；
            // 但**用户自建的分组即使空的也要显示** —— 否则新建完看不到，
            // 用户会以为"没反应"，也没地方把曲目拖进去。
            if list.isEmpty && category.isBuiltin { continue }
            result.append((category, list))
            emitted.insert(category.key)
        }
        // 兜底：出现了但没在分组表里的 key（比如历史数据）
        for (key, list) in byKey.sorted(by: { $0.key < $1.key }) where !emitted.contains(key) {
            let title = WorkCategory.builtin(forKey: key)?.title ?? key
            result.append((WorkCategory(key: key, title: title, sortOrder: 999, isBuiltin: true), list))
        }
        return result
    }

    // MARK: - 分组管理

    /// 该作品当前的分组列表（内置 + 自定义）
    public func categories(workID: Int64) throws -> [WorkCategory] {
        let custom = try customCategories(workID: workID)
        var list = WorkCategory.builtins + [.attachments]
        let settings = try db.query("SELECT category_title_overrides, category_order FROM work WHERE id = ?", [.integer(workID)]).first
        let titles = settings?.string("category_title_overrides").flatMap {
            try? JSONDecoder().decode([String: String].self, from: Data($0.utf8))
        } ?? [:]
        list.append(contentsOf: custom)
        // A legacy key that still owns files is a real group, even if its old category entry was lost.
        let knownKeys = Set(list.map(\.key))
        let usedKeys = try db.query("""
            SELECT COALESCE(category_override, category) AS key FROM track WHERE work_id = ?
            UNION SELECT category_key FROM work_attachment WHERE work_id = ? ORDER BY key
            """, [.integer(workID), .integer(workID)]).compactMap { $0.string("key") }
        for key in usedKeys where !knownKeys.contains(key) {
            list.append(WorkCategory(key: key, title: key, sortOrder: list.count, isBuiltin: true))
        }
        for index in list.indices where list[index].isBuiltin {
            if let title = titles[list[index].key] { list[index].title = title }
        }
        let json = settings?.string("category_order")
        let saved = json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
        let byKey = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
        return saved.compactMap { byKey[$0] } + list.filter { !saved.contains($0.key) }
    }

    public func customCategories(workID: Int64) throws -> [WorkCategory] {
        let rows = try db.query("SELECT custom_categories FROM work WHERE id = ?", [.integer(workID)])
        return CustomCategoryCodec.decode(rows.first?.string("custom_categories"))
    }

    /// 新建一个自定义分组
    @discardableResult
    public func addCustomCategory(workID: Int64, title: String) throws -> WorkCategory {
        var existing = try customCategories(workID: workID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmed.isEmpty ? "新分组" : trimmed

        // 同名去重
        if let same = existing.first(where: { $0.title == finalTitle }) { return same }

        let key = CustomCategoryCodec.newKey(existing: existing)
        let nextOrder = (existing.map(\.sortOrder).max() ?? WorkCategory.builtins.count) + 1
        let category = WorkCategory(key: key, title: finalTitle, sortOrder: nextOrder, isBuiltin: false)
        existing.append(category)
        try saveCustomCategories(workID: workID, existing)
        return category
    }

    public func renameCustomCategory(workID: Int64, key: String, title: String) throws {
        var existing = try customCategories(workID: workID)
        guard let index = existing.firstIndex(where: { $0.key == key }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        existing[index].title = trimmed
        try saveCustomCategories(workID: workID, existing)
    }

    /// 更名只改变显示名，内置分类 key 和曲目归属不变。
    public func renameCategory(workID: Int64, key: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryEditingError.blankCategoryTitle }
        try db.transaction {
            guard try work(id: workID) != nil else { throw LibraryEditingError.missingWork }
            let current = try categories(workID: workID)
            guard let category = current.first(where: { $0.key == key }) else { throw LibraryEditingError.missingCategory }
            guard !current.contains(where: { $0.key != key && $0.title == trimmed }) else {
                throw LibraryEditingError.duplicateCategoryTitle
            }
            if category.isBuiltin {
                let encoded = try db.query("SELECT category_title_overrides FROM work WHERE id = ?", [.integer(workID)])
                    .first?.string("category_title_overrides")
                var titles = encoded.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
                titles[key] = trimmed
                let json = String(decoding: try JSONEncoder().encode(titles), as: UTF8.self)
                try db.execute("UPDATE work SET category_title_overrides = ?, updated_at = ? WHERE id = ?",
                               [.text(json), SQLValue(Date()), .integer(workID)])
            } else {
                try renameCustomCategory(workID: workID, key: key, title: trimmed)
            }
        }
    }

    /// 删除自定义分组：里面的曲目回到"自动识别"的分类
    public func removeCustomCategory(workID: Int64, key: String) throws {
        var existing = try customCategories(workID: workID)
        guard existing.contains(where: { $0.key == key }) else { return }
        try db.transaction {
            let keys = try categories(workID: workID).map(\.key).filter { $0 != key }
            existing.removeAll { $0.key == key }
            try saveCustomCategories(workID: workID, existing)
            try saveCategoryOrder(workID: workID, keys: keys)
            try db.execute("UPDATE track SET category_override = NULL WHERE work_id = ? AND category_override = ?",
                           [.integer(workID), .text(key)])
            try db.execute("UPDATE work_attachment SET category_key = 'attachments' WHERE work_id = ? AND category_key = ?",
                           [.integer(workID), .text(key)])
        }
    }

    private func saveCustomCategories(workID: Int64, _ categories: [WorkCategory]) throws {
        try db.execute(
            "UPDATE work SET custom_categories = ?, updated_at = ? WHERE id = ?",
            [.optional(CustomCategoryCodec.encode(categories)), SQLValue(Date()), .integer(workID)]
        )
    }

    /// 把某些曲目手动归到指定分组（传 nil 恢复自动识别）
    public func setCategoryOverride(workID: Int64, trackIDs: [Int64], key: String?) throws {
        guard !trackIDs.isEmpty else { return }
        let placeholders = trackIDs.map { _ in "?" }.joined(separator: ",")
        var params: [SQLValue] = [.optional(key), .integer(workID)]
        params.append(contentsOf: trackIDs.map { SQLValue.integer($0) })
        try db.execute(
            "UPDATE track SET category_override = ? WHERE work_id = ? AND id IN (\(placeholders))",
            params
        )
    }

    /// 手动排序：按给定顺序整体重排
    public func setTrackOrder(workID: Int64, orderedTrackIDs: [Int64]) throws {
        guard !orderedTrackIDs.isEmpty else { return }
        try db.transaction {
            for (index, trackID) in orderedTrackIDs.enumerated() {
                try db.execute(
                    "UPDATE track SET sort_order = ? WHERE work_id = ? AND id = ?",
                    [.integer(index), .integer(workID), .integer(trackID)]
                )
            }
        }
    }

    /// 验证完整快照后同时保存分组与顺序；扫描或其他编辑改变列表时拒绝过期操作。
    public func commitTrackMove(workID: Int64, trackIDs: [Int64], toCategory key: String,
                                orderedTrackIDs: [Int64]) throws {
        try db.transaction {
            guard try work(id: workID) != nil else { throw LibraryEditingError.missingWork }
            guard try categories(workID: workID).contains(where: { $0.key == key }) else {
                throw LibraryEditingError.missingCategory
            }
            let currentIDs = Set(try tracks(workID: workID).map(\.id))
            let selected = Set(trackIDs)
            guard !selected.isEmpty, selected.count == trackIDs.count, selected.isSubset(of: currentIDs),
                  orderedTrackIDs.count == currentIDs.count, Set(orderedTrackIDs) == currentIDs else {
                throw LibraryEditingError.staleTrackOrder
            }
            try setCategoryOverride(workID: workID, trackIDs: trackIDs, key: key)
            try setTrackOrder(workID: workID, orderedTrackIDs: orderedTrackIDs)
        }
    }

    private func mapTrackRow(_ row: SQLRow) -> TrackRecord {
        TrackRecord(
            id: row.int64("id") ?? 0,
            workID: row.int64("work_id") ?? 0,
            fileName: row.string("file_name") ?? "",
            filePath: row.string("file_path") ?? "",
            relativePath: row.string("relative_path"),
            fileType: row.string("file_type") ?? "",
            isVideo: row.bool("is_video"),
            trackIndex: row.int("track_index") ?? 0,
            title: row.string("title_override") ?? row.string("title"),
            durationMS: row.int("duration_ms"),
            fileSize: row.int64("file_size"),
            fileMtime: row.date("file_mtime"),
            createdAt: row.date("created_at") ?? Date(),
            category: TrackCategory(rawValue: row.string("category") ?? "main") ?? .main,
            categoryOverride: row.string("category_override"),
            sortOrder: row.int("sort_order") ?? 0,
            assetRelativePath: row.string("asset_relative_path")
        )
    }

    // MARK: - 统计数字

    public func counts() throws -> (works: Int, tracks: Int) {
        let works = try db.queryInt("SELECT COUNT(*) FROM work") ?? 0
        let tracks = try db.queryInt("SELECT COUNT(*) FROM track") ?? 0
        return (works, tracks)
    }

    // MARK: - 设置

    public func setSetting(_ key: String, _ value: String) throws {
        try db.execute(
            """
            INSERT INTO app_setting (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """,
            [.text(key), .text(value), SQLValue(Date())]
        )
    }

    public func setting(_ key: String) throws -> String? {
        try db.query("SELECT value FROM app_setting WHERE key = ?", [.text(key)]).first?.string("value")
    }

    // MARK: - 内部

    private func mapWorkRow(_ row: SQLRow) -> WorkRecord {
        var work = WorkRecord(
            id: row.int64("id") ?? 0,
            title: row.string("display_work_title") ?? row.string("title_override") ?? row.string("title") ?? "",
            rjCode: (row.string("rj_code_override") ?? row.string("rj_code")).flatMap { $0.isEmpty ? nil : $0 },
            circleName: row.string("circle_name"),
            seiyuuName: row.string("seiyuu_name"),
            coverPath: row.string("cover_path"),
            folderPath: row.string("folder_path") ?? "",
            folderRelativePath: row.string("folder_rel") ?? "",
            sourceID: row.int64("source_id") ?? 0,
            rating: row.int("rating") ?? 0,
            favorite: row.bool("favorite"),
            listened: row.bool("listened"),
            playCount: row.int("play_count") ?? 0,
            lastPlayedTrackID: row.int64("last_played_track_id"),
            lastPlayedPositionMS: row.int("last_played_position") ?? 0,
            scriptPath: row.string("script_path"),
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            libraryKind: MediaLibraryKind(rawValue: row.string("library_kind") ?? "collection") ?? .collection,
            creatorID: row.int64("creator_id")
        )
        work.trackCount = row.int("track_count") ?? 0
        work.videoCount = row.int("video_count") ?? 0
        work.totalDurationMS = row.int("total_duration") ?? 0
        if let circle = row.string("circle_name_override") { work.circleName = circle }
        if let encoded = row.string("seiyuu_names_override"),
           let names = try? JSONDecoder().decode([String].self, from: Data(encoded.utf8)) {
            work.seiyuuNames = names
            work.seiyuuName = names.joined(separator: "、")
        }
        work.coverAssetPath = row.string("cover_asset_path")
        work.playerCoverMode = row.string("player_cover_mode").flatMap(PlayerCoverMode.init(rawValue:)) ?? .original
        return work
    }
}

public enum LibraryEditingError: LocalizedError {
    case unavailable, missingWork, invalidAssetPath, blankTitle, invalidRJ
    case blankCategoryTitle, missingCategory, duplicateCategoryTitle, staleTrackOrder

    public var errorDescription: String? {
        switch self {
        case .unavailable: return InterfaceLocalization.text("媒体库尚未就绪，请稍后重试。")
        case .missingWork: return InterfaceLocalization.text("这部作品已不在媒体库中。")
        case .invalidAssetPath: return InterfaceLocalization.text("文件位置无效，请重新选择文件。")
        case .invalidRJ: return InterfaceLocalization.text("作品编号可以留空，或填写 RJ、BJ 加数字，例如 BJ123456。只填数字会按 RJ 保存。")
        case .blankTitle: return InterfaceLocalization.text("作品名称不能为空。")
        case .blankCategoryTitle: return InterfaceLocalization.text("分组名称不能为空。")
        case .missingCategory: return InterfaceLocalization.text("这个分组已不存在，请重新选择。")
        case .duplicateCategoryTitle: return InterfaceLocalization.text("已有同名分组，请换一个名称。")
        case .staleTrackOrder: return InterfaceLocalization.text("曲目列表已有变化，请重新整理。")
        }
    }
}

