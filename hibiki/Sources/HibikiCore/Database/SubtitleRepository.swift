import Foundation

/// 字幕轨来源类型
public enum SubtitleTrackKind: String, Codable, Sendable, CaseIterable {
    /// 同目录的同名字幕文件
    case sidecar
    /// 用户手动选的文件
    case manual
    /// 音频文件里内嵌的歌词/字幕
    case embedded
    /// AI 识别生成
    case ai
    /// 从台本对齐得到
    case script

    public var displayName: String {
        switch self {
        case .sidecar: return InterfaceLocalization.text("外挂字幕")
        case .manual: return InterfaceLocalization.text("手动导入")
        case .embedded: return InterfaceLocalization.text("内嵌字幕")
        case .ai: return InterfaceLocalization.text("AI 识别")
        case .script: return InterfaceLocalization.text("台本对齐")
        }
    }
}

/// 一条字幕轨（对应数据库 `subtitle_track`）
public struct SubtitleTrackRecord: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var trackID: Int64
    public var kind: SubtitleTrackKind
    public var language: String?
    public var label: String
    public var isActive: Bool
    public var prefersTimedSidecar = false
    public var createdAt: Date
    /// 版本数（查询时聚合）
    public var versionCount: Int = 0
    /// 当前版本条目数（查询时聚合）
    public var cueCount: Int = 0
    /// 当前最新版本的 id
    public var latestVersionID: Int64?

    public init(
        id: Int64 = 0,
        trackID: Int64,
        kind: SubtitleTrackKind,
        language: String? = nil,
        label: String,
        isActive: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.trackID = trackID
        self.kind = kind
        self.language = language
        self.label = label
        self.isActive = isActive
        self.createdAt = createdAt
    }

    public var displayLabel: String {
        if let language, !language.isEmpty, !label.contains(language) {
            return "\(label)（\(language)）"
        }
        return label
    }
}

/// 一个字幕版本（对应数据库 `subtitle_version`）
public struct SubtitleVersionRecord: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var subtitleTrackID: Int64
    public var versionNo: Int
    public var note: String
    public var isBaseline: Bool
    public var isPinned: Bool
    public var cueCount: Int
    public var createdAt: Date

    public init(
        id: Int64 = 0,
        subtitleTrackID: Int64,
        versionNo: Int = 1,
        note: String = "",
        isBaseline: Bool = true,
        isPinned: Bool = false,
        cueCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.subtitleTrackID = subtitleTrackID
        self.versionNo = versionNo
        self.note = note
        self.isBaseline = isBaseline
        self.isPinned = isPinned
        self.cueCount = cueCount
        self.createdAt = createdAt
    }

    public var displayName: String {
        "v\(versionNo)" + (note.isEmpty ? "" : " · \(note)")
    }
}

/// 字幕历史的逻辑内容量，不含 SQLite 页、索引、WAL 或文件系统开销。
/// 删除后数据库可以复用页面；此值不是本次操作将立即释放的磁盘空间。
public struct SubtitleHistoryCleanupSummary: Equatable, Sendable {
    public var versionCount: Int
    public var cueCount: Int
    public var estimatedContentBytes: Int64

    public init(versionCount: Int = 0, cueCount: Int = 0, estimatedContentBytes: Int64 = 0) {
        self.versionCount = versionCount
        self.cueCount = cueCount
        self.estimatedContentBytes = estimatedContentBytes
    }
}

/// 字幕的读写
public final class SubtitleRepository {

    private let db: SQLiteDatabase

    public init(database: SQLiteDatabase) {
        self.db = database
    }

    /// 多份文件一起提交。任何一份保存失败，之前写入的文件也回滚。
    @discardableResult
    public func importScriptFiles(_ files: [(name: String, rows: [ScriptImportAssignment])],
                                  activate: Bool, durationsMS: [Int64: Int] = [:],
                                  legacyNames: [String: Set<String>] = [:]) throws -> Int {
        return try db.transaction {
            var count = 0
            var seenBySource: [String: Set<Int64>] = [:]
            var seenTracks: Set<Int64> = []
            for file in files {
                let ids = file.rows.compactMap(\.trackID)
                if ids.isEmpty { continue }
                let targets = Set(ids)
                guard targets.count == ids.count, seenBySource[file.name, default: []].isDisjoint(with: targets) else {
                    throw ScriptImportFailure.duplicateTrack
                }
                seenBySource[file.name, default: []].formUnion(targets)
                // 多语言台本可以指向同一首；多个新来源只激活用户先选的那份。
                count += try importSections(file.rows, fileName: file.name, automatically: false,
                                            activateTargets: activate ? targets.subtracting(seenTracks) : [], durationsMS: durationsMS,
                                            legacyNames: legacyNames[file.name] ?? [])
                seenTracks.formUnion(targets)
            }
            guard count > 0 else { throw ScriptImportFailure.noSelection }
            return count
        }
    }

    /// 整部作品的台本一次性入库；保留已有来源与所有人工版本。
    @discardableResult
    public func importScriptSections(
        _ assignments: [ScriptImportAssignment],
        fileName: String,
        activateOverTimedSubtitles: Bool = false,
        automatically: Bool = false,
        durationsMS: [Int64: Int] = [:]
    ) throws -> Int {
        try importSections(assignments, fileName: fileName, automatically: automatically,
                           activateTargets: activateOverTimedSubtitles ? Set(assignments.compactMap(\.trackID)) : [],
                           durationsMS: durationsMS)
    }

    private func importSections(_ assignments: [ScriptImportAssignment], fileName: String, automatically: Bool,
                                activateTargets: Set<Int64>, durationsMS: [Int64: Int], legacyNames: Set<String> = []) throws -> Int {
        let selected = assignments.filter { $0.trackID != nil }
        guard !selected.isEmpty else { throw ScriptImportFailure.noSelection }
        let ids = selected.compactMap(\.trackID)
        guard Set(ids).count == ids.count else { throw ScriptImportFailure.duplicateTrack }
        return try db.transaction {
            assignmentsLoop: for assignment in selected {
                guard let trackID = assignment.trackID else { continue }
                let cues = ScriptImportPlan.cues(for: assignment.section, durationMS: durationsMS[trackID])
                guard !cues.isEmpty else { throw ScriptImportFailure.emptySection }
                let hasPrintedTimes = cues.contains { $0.status == .provisional }
                let hasCompleteTimes = cues.contains { $0.status == .ok && $0.hasTiming }
                let note = automatically
                    ? (hasPrintedTimes ? Self.printedScriptNote : hasCompleteTimes ? Self.completeScriptNote : Self.automaticScriptNote)
                    : (hasPrintedTimes ? "手动导入台本 · 采用印刷起点，结束待校准" : hasCompleteTimes ? "手动导入台本 · 采用完整印刷时间" : "台本文字导入 · 尚未设置时间")
                let existing = try tracks(forTrackID: trackID)
                let label = "\(fileName) · \(assignment.section.displayName)"
                let sectionLabel = assignment.section.trackNumber.map { "第\($0)轨" } ?? "整份台本"
                let automaticLabel = "\(fileName) · \(sectionLabel)"
                if automatically {
                    for prior in existing where prior.kind == .script && prior.label == automaticLabel {
                        guard let baseline = try versions(subtitleTrackID: prior.id).first,
                              [Self.automaticScriptNote, Self.printedScriptNote, Self.completeScriptNote].contains(baseline.note) else { continue }
                        // 只更新未经过手改的自动底稿。重复扫描不增加字幕来源或版本。
                        if prior.versionCount == 1 && !baseline.isPinned {
                            let old = try self.cues(versionID: baseline.id)
                            if !old.elementsEqual(cues, by: Self.sameImportedCue) {
                                try replaceCues(versionID: baseline.id, with: cues)
                            }
                            if baseline.note != note {
                                try db.execute("UPDATE subtitle_version SET note = ? WHERE id = ?", [.text(note), .integer(baseline.id)])
                            }
                        }
                        continue assignmentsLoop
                    }
                }
                // 旧版自动、手选使用两种不同的章节标签。只在路径和原稿内容均相符时复用。
                let oldLabels = Set(legacyNames.map { "\($0) · \(assignment.section.displayName)" })
                let prior = try existing.first { prior in
                    guard prior.kind == .script, prior.label == label || prior.label == automaticLabel || oldLabels.contains(prior.label),
                          let baseline = try versions(subtitleTrackID: prior.id).first else { return false }
                    return try self.cues(versionID: baseline.id).elementsEqual(cues, by: Self.sameImportedCue)
                }
                if let prior {
                    if oldLabels.contains(prior.label) {
                        try db.execute("UPDATE subtitle_track SET label = ? WHERE id = ?", [.text(label), .integer(prior.id)])
                    }
                    if !automatically && activateTargets.contains(trackID) {
                        try activateTrack(trackID: trackID, subtitleTrackID: prior.id)
                    }
                    continue
                }
                let activate = existing.isEmpty || (!automatically && activateTargets.contains(trackID))
                try createTrack(
                    trackID: trackID, kind: .script, language: nil, label: automatically ? automaticLabel : label,
                    cues: cues, note: note,
                    activate: activate, prefersTimedSidecar: automatically && activate
                )
            }
            return selected.count
        }
    }

    private static let automaticScriptNote = "从作品 PDF 自动识别 · 尚未设置时间"
    private static let printedScriptNote = "从作品 PDF 初步对齐 · 采用印刷起点，结束待校准"
    private static let completeScriptNote = "从作品 PDF 导入 · 采用完整印刷时间"

    private static func sameImportedCue(_ left: SubtitleCue, _ right: SubtitleCue) -> Bool {
        left.text == right.text && left.speaker == right.speaker && left.translatedText == right.translatedText
            && left.startMS == right.startMS && left.endMS == right.endMS && left.status == right.status
    }

    /// 后来才添加的带轴外挂，可以替代首次扫描时自动启用且从未编辑的阅读底稿。
    public func shouldActivateNewSidecar(alongside existing: [SubtitleTrackRecord]) -> Bool {
        if existing.isEmpty { return true }
        guard let active = existing.first(where: \.isActive) else { return false }
        return active.prefersTimedSidecar && active.versionCount == 1
    }

    // MARK: - 字幕轨

    /// 新建一条字幕轨并写入第一版条目
    @discardableResult
    public func createTrack(
        trackID: Int64,
        kind: SubtitleTrackKind,
        language: String?,
        label: String,
        cues: [SubtitleCue],
        note: String = "导入",
        activate: Bool = true,
        prefersTimedSidecar: Bool = false
    ) throws -> (track: Int64, version: Int64) {
        try db.transaction {
            try db.execute(
                """
                INSERT INTO subtitle_track (track_id, kind, language, label, is_active, created_at, prefers_timed_sidecar)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .integer(trackID),
                    .text(kind.rawValue),
                    .optional(language),
                    .text(label),
                    .integer(activate),
                    SQLValue(Date()),
                    .integer(prefersTimedSidecar)
                ]
            )
            let trackRowID = db.lastInsertRowID
            let versionID = try insertVersion(
                subtitleTrackID: trackRowID,
                versionNo: 1,
                note: note,
                isBaseline: true,
                cues: cues
            )
            if activate {
                try db.execute("UPDATE subtitle_track SET is_active = 0 WHERE track_id = ? AND id <> ?",
                               [.integer(trackID), .integer(trackRowID)])
            }
            return (trackRowID, versionID)
        }
    }

    /// 该曲目的所有字幕轨
    public func tracks(forTrackID trackID: Int64) throws -> [SubtitleTrackRecord] {
        let rows = try db.query(
            """
            SELECT st.*,
                   (SELECT COUNT(*) FROM subtitle_version v WHERE v.subtitle_track_id = st.id) AS version_count,
                   (SELECT id FROM subtitle_version v WHERE v.subtitle_track_id = st.id
                     ORDER BY v.version_no DESC LIMIT 1) AS latest_version_id,
                   (SELECT cue_count FROM subtitle_version v WHERE v.subtitle_track_id = st.id
                     ORDER BY v.version_no DESC LIMIT 1) AS cue_count
              FROM subtitle_track st
             WHERE st.track_id = ?
             ORDER BY st.is_active DESC, st.created_at
            """,
            [.integer(trackID)]
        )
        return rows.map { row in
            var record = SubtitleTrackRecord(
                id: row.int64("id") ?? 0,
                trackID: row.int64("track_id") ?? 0,
                kind: SubtitleTrackKind(rawValue: row.string("kind") ?? "sidecar") ?? .sidecar,
                language: row.string("language"),
                label: row.string("label") ?? "字幕",
                isActive: row.bool("is_active"),
                createdAt: row.date("created_at") ?? Date()
            )
            record.prefersTimedSidecar = row.bool("prefers_timed_sidecar")
            record.versionCount = row.int("version_count") ?? 0
            record.cueCount = row.int("cue_count") ?? 0
            record.latestVersionID = row.int64("latest_version_id")
            return record
        }
    }

    /// 启用某条字幕轨（同曲目其他轨自动取消激活）
    public func activateTrack(trackID: Int64, subtitleTrackID: Int64?) throws {
        try db.transaction {
            if let id = subtitleTrackID {
                guard try db.queryInt("SELECT COUNT(*) FROM subtitle_track WHERE id = ? AND track_id = ?",
                                      [.integer(id), .integer(trackID)]) == 1 else { return }
            }
            try db.execute("UPDATE subtitle_track SET is_active = 0 WHERE track_id = ?", [.integer(trackID)])
            if let id = subtitleTrackID {
                try db.execute("UPDATE subtitle_track SET is_active = 1, prefers_timed_sidecar = 0 WHERE id = ?",
                               [.integer(id)])
            }
        }
    }

    /// 关掉该曲目的所有字幕
    public func deactivateAll(trackID: Int64) throws {
        try activateTrack(trackID: trackID, subtitleTrackID: nil)
    }

    public func deleteTrack(_ subtitleTrackID: Int64) throws {
        try db.execute("DELETE FROM subtitle_track WHERE id = ?", [.integer(subtitleTrackID)])
    }

    /// 删除某个曲目下某一来源类型的旧字幕轨（重新导入外挂字幕时用）
    public func deleteTracks(trackID: Int64, kind: SubtitleTrackKind) throws {
        try db.execute(
            "DELETE FROM subtitle_track WHERE track_id = ? AND kind = ?",
            [.integer(trackID), .text(kind.rawValue)]
        )
    }

    // MARK: - 版本

    @discardableResult
    public func insertVersion(
        subtitleTrackID: Int64,
        versionNo: Int? = nil,
        note: String,
        isBaseline: Bool,
        cues: [SubtitleCue]
    ) throws -> Int64 {
        try db.transaction {
            let latestNumber = try db.queryInt(
                "SELECT MAX(version_no) FROM subtitle_version WHERE subtitle_track_id = ?",
                [.integer(subtitleTrackID)]
            ) ?? 0
            let number: Int
            if let versionNo {
                guard versionNo > latestNumber else { throw SubtitleHistoryFailure.invalidVersionNumber }
                number = versionNo
            } else {
                guard latestNumber < Int.max else { throw SubtitleHistoryFailure.invalidVersionNumber }
                number = latestNumber + 1
            }

            try db.execute(
                """
                INSERT INTO subtitle_version
                    (subtitle_track_id, version_no, note, is_baseline, cue_count, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [
                    .integer(subtitleTrackID),
                    .integer(number),
                    .text(note),
                    .integer(isBaseline),
                    .integer(cues.count),
                    SQLValue(Date())
                ]
            )
            let versionID = db.lastInsertRowID
            try insertCues(cues, versionID: versionID)
            return versionID
        }
    }

    public func versions(subtitleTrackID: Int64) throws -> [SubtitleVersionRecord] {
        let rows = try db.query(
            "SELECT * FROM subtitle_version WHERE subtitle_track_id = ? ORDER BY version_no",
            [.integer(subtitleTrackID)]
        )
        return rows.map { row in
            SubtitleVersionRecord(
                id: row.int64("id") ?? 0,
                subtitleTrackID: row.int64("subtitle_track_id") ?? 0,
                versionNo: row.int("version_no") ?? 1,
                note: row.string("note") ?? "",
                isBaseline: row.bool("is_baseline"),
                isPinned: row.bool("is_pinned"),
                cueCount: row.int("cue_count") ?? 0,
                createdAt: row.date("created_at") ?? Date()
            )
        }
    }

    /// 固定/取消固定不新建版本、不切换当前来源，也不修改字幕内容。
    /// 返回 false 表示这个版本已经不存在，调用方应刷新列表。
    @discardableResult
    public func setVersionPinned(_ versionID: Int64, isPinned: Bool) throws -> Bool {
        try db.execute("UPDATE subtitle_version SET is_pinned = ? WHERE id = ?",
                       [.integer(isPinned), .integer(versionID)]) == 1
    }

    public func pinnedVersions(subtitleTrackID: Int64) throws -> [SubtitleVersionRecord] {
        try versions(subtitleTrackID: subtitleTrackID).filter(\.isPinned)
    }

    /// 恢复同一音轨的任意来源快照：新增版本与切换来源一起提交，旧快照保持原样。
    @discardableResult
    public func restoreVersion(_ versionID: Int64, trackID: Int64) throws -> Int64 {
        try db.transaction {
            guard let original = try db.query("""
                SELECT v.subtitle_track_id, v.version_no FROM subtitle_version v
                JOIN subtitle_track st ON st.id = v.subtitle_track_id
                WHERE v.id = ? AND st.track_id = ?
                """, [.integer(versionID), .integer(trackID)]).first,
                  let sourceID = original.int64("subtitle_track_id"),
                  let number = original.int("version_no") else {
                throw SubtitleHistoryFailure.versionUnavailable
            }
            let restored = try insertVersion(subtitleTrackID: sourceID, note: "恢复自 v\(number)",
                                             isBaseline: false, cues: [])
            let count = try db.execute("""
                INSERT INTO subtitle_cue (version_id, cue_index, start_ms, end_ms, source_text, translated_text, speaker, status)
                SELECT ?, cue_index, start_ms, end_ms, source_text, translated_text, speaker, status
                  FROM subtitle_cue WHERE version_id = ? ORDER BY cue_index, id
                """, [.integer(restored), .integer(versionID)])
            try db.execute("UPDATE subtitle_version SET cue_count = ? WHERE id = ?", [.integer(count), .integer(restored)])
            try activateTrack(trackID: trackID, subtitleTrackID: sourceID)
            return restored
        }
    }

    /// 全库候选：每来源的原始、最早、最新、固定版本和调用方给出的草稿基准均不删除。
    /// 预览是只读查询；真正清理会在写事务内重新计算，避免预览后又固定了某一版。
    public func historyCleanupSummary(protectingVersionIDs: Set<Int64> = []) throws -> SubtitleHistoryCleanupSummary {
        let row = try db.query("""
            WITH candidates AS (\(historyCandidates(protectingVersionIDs: protectingVersionIDs)))
            SELECT (SELECT COUNT(*) FROM candidates) AS version_count,
                   (SELECT COUNT(*) FROM subtitle_cue WHERE version_id IN (SELECT id FROM candidates)) AS cue_count,
                   COALESCE((SELECT SUM(length(CAST(COALESCE(note, '') AS BLOB)))
                               FROM subtitle_version WHERE id IN (SELECT id FROM candidates)), 0)
                   + COALESCE((SELECT SUM(length(CAST(source_text AS BLOB))
                                          + length(CAST(COALESCE(translated_text, '') AS BLOB))
                                          + length(CAST(COALESCE(speaker, '') AS BLOB)))
                                 FROM subtitle_cue WHERE version_id IN (SELECT id FROM candidates)), 0)
                     AS content_bytes
            """).first
        return SubtitleHistoryCleanupSummary(versionCount: row?.int("version_count") ?? 0,
            cueCount: row?.int("cue_count") ?? 0, estimatedContentBytes: row?.int64("content_bytes") ?? 0)
    }

    /// 删除未固定的旧历史及它们自己的字幕行，保留所有来源、关联和阅读位置。
    /// 编号不压缩；每来源最新版本始终保留，下一次保存继续 MAX(version_no) + 1。
    @discardableResult
    public func cleanupUnpinnedHistory(protectingVersionIDs: Set<Int64> = []) throws -> SubtitleHistoryCleanupSummary {
        try db.transaction {
            let summary = try historyCleanupSummary(protectingVersionIDs: protectingVersionIDs)
            guard summary.versionCount > 0 else { return summary }
            let removed = try db.execute("""
                DELETE FROM subtitle_version WHERE id IN (\(historyCandidates(protectingVersionIDs: protectingVersionIDs)))
                """)
            guard removed == summary.versionCount else { throw SubtitleHistoryFailure.cleanupChanged }
            return summary
        }
    }

    private func historyCandidates(protectingVersionIDs: Set<Int64>) -> String {
        // These values are typed Int64 identifiers, never user-supplied SQL/text.
        // Inline numbers avoid SQLite's bound-parameter limit for many saved drafts.
        let protected = protectingVersionIDs.isEmpty ? "" :
            " AND v.id NOT IN (" + protectingVersionIDs.sorted().map(String.init).joined(separator: ",") + ")"
        return """
            SELECT v.id FROM subtitle_version v
             WHERE v.is_baseline = 0 AND v.is_pinned = 0
               AND EXISTS (SELECT 1 FROM subtitle_version older
                            WHERE older.subtitle_track_id = v.subtitle_track_id AND older.version_no < v.version_no)
               AND EXISTS (SELECT 1 FROM subtitle_version newer
                            WHERE newer.subtitle_track_id = v.subtitle_track_id AND newer.version_no > v.version_no)
            """ + protected
    }

    /// 为加号新建一版：已保存的整份台本在数据库内复制，不逐句往返 Swift，也不改旧版。
    /// 若调用方仍有尚未保存的修改，则把这份明确提供的快照一起保存。
    @discardableResult
    public func insertBlankVersion(copying versionID: Int64, after index: Int,
                                   pendingCues: [SubtitleCue]? = nil) throws -> Int64 {
        try db.transaction {
            guard let source = try db.query("""
                    SELECT v.subtitle_track_id FROM subtitle_version v
                    JOIN subtitle_track st ON st.id = v.subtitle_track_id
                    WHERE v.id = ? AND st.is_active = 1
                    """, [.integer(versionID)]).first,
                  let subtitleTrackID = source.int64("subtitle_track_id"),
                  try db.query("SELECT id FROM subtitle_version WHERE subtitle_track_id = ? ORDER BY version_no DESC LIMIT 1",
                               [.integer(subtitleTrackID)]).first?.int64("id") == versionID else {
                throw SubtitleInsertFailure.versionChanged
            }
            let count = try pendingCues?.count ?? db.queryInt("SELECT COUNT(*) FROM subtitle_cue WHERE version_id = ?", [.integer(versionID)]) ?? 0
            guard (count == 0 && index == -1) || (index >= 0 && index < count) else {
                throw SubtitleInsertFailure.invalidRow
            }
            if var pendingCues {
                pendingCues.insert(SubtitleCue(index: index + 1, startMS: 0, endMS: 0, text: "", status: .untimed), at: index + 1)
                return try insertVersion(subtitleTrackID: subtitleTrackID, note: "增加空白字幕行",
                                         isBaseline: false, cues: CueEditor.reindex(pendingCues))
            }
            let newID = try insertVersion(subtitleTrackID: subtitleTrackID, note: "增加空白字幕行", isBaseline: false, cues: [])
            // schema 中所有字幕内容字段原样复制；只改变所属版本与空行之后的顺序。
            try db.execute("""
                INSERT INTO subtitle_cue (version_id, cue_index, start_ms, end_ms, source_text, translated_text, speaker, status)
                SELECT ?, CASE WHEN ordinal > ? THEN ordinal + 1 ELSE ordinal END,
                       start_ms, end_ms, source_text, translated_text, speaker, status
                  FROM (SELECT ROW_NUMBER() OVER (ORDER BY cue_index, id) - 1 AS ordinal,
                               start_ms, end_ms, source_text, translated_text, speaker, status
                          FROM subtitle_cue WHERE version_id = ?)
                 ORDER BY ordinal
                """, [.integer(newID), .integer(index), .integer(versionID)])
            try db.execute("""
                INSERT INTO subtitle_cue (version_id, cue_index, start_ms, end_ms, source_text, translated_text, speaker, status)
                VALUES (?, ?, 0, 0, '', NULL, NULL, 'untimed')
                """, [.integer(newID), .integer(index + 1)])
            try db.execute("UPDATE subtitle_version SET cue_count = ? WHERE id = ?", [.integer(count + 1), .integer(newID)])
            return newID
        }
    }

    public func deleteVersion(_ versionID: Int64, protectingVersionIDs: Set<Int64> = []) throws {
        try db.execute("DELETE FROM subtitle_version WHERE id = ? AND id IN (\(historyCandidates(protectingVersionIDs: protectingVersionIDs)))",
                       [.integer(versionID)])
    }

    // MARK: - 条目

    private func insertCues(_ cues: [SubtitleCue], versionID: Int64) throws {
        for (index, cue) in cues.enumerated() {
            try db.execute(
                """
                INSERT INTO subtitle_cue
                    (version_id, cue_index, start_ms, end_ms, source_text, translated_text, speaker, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .integer(versionID),
                    .integer(index),
                    .integer(cue.startMS),
                    .integer(cue.endMS),
                    .text(cue.text),
                    .optional(cue.translatedText),
                    .optional(cue.speaker),
                    .text(cue.status.rawValue)
                ]
            )
        }
    }

    public func cues(versionID: Int64) throws -> [SubtitleCue] {
        let rows = try db.query(
            "SELECT * FROM subtitle_cue WHERE version_id = ? ORDER BY cue_index",
            [.integer(versionID)]
        )
        return rows.map { row in
            SubtitleCue(
                index: row.int("cue_index") ?? 0,
                startMS: row.int("start_ms") ?? 0,
                endMS: row.int("end_ms") ?? 0,
                text: row.string("source_text") ?? "",
                translatedText: row.string("translated_text"),
                speaker: row.string("speaker"),
                status: CueStatus(rawValue: row.string("status") ?? "ok") ?? .ok
            )
        }
    }

    /// 该曲目**当前生效**的字幕条目
    public func activeCues(trackID: Int64) throws -> [SubtitleCue] {
        let rows = try db.query(
            """
            SELECT v.id AS version_id
              FROM subtitle_track st
              JOIN subtitle_version v ON v.subtitle_track_id = st.id
             WHERE st.track_id = ? AND st.is_active = 1
             ORDER BY v.version_no DESC
             LIMIT 1
            """,
            [.integer(trackID)]
        )
        guard let versionID = rows.first?.int64("version_id") else { return [] }
        return try cues(versionID: versionID)
    }

    /// 用一批新条目替换某个版本的内容（编辑字幕时用）
    public func replaceCues(versionID: Int64, with cues: [SubtitleCue]) throws {
        try db.transaction {
            try db.execute("DELETE FROM subtitle_cue WHERE version_id = ?", [.integer(versionID)])
            try insertCues(cues, versionID: versionID)
            try db.execute(
                "UPDATE subtitle_version SET cue_count = ? WHERE id = ?",
                [.integer(cues.count), .integer(versionID)]
            )
        }
    }

    /// 清除某个曲目的全部字幕（含所有版本）
    public func clearSubtitles(trackID: Int64) throws -> Int {
        let count = try db.queryInt(
            "SELECT COUNT(*) FROM subtitle_track WHERE track_id = ?",
            [.integer(trackID)]
        ) ?? 0
        try db.execute("DELETE FROM subtitle_track WHERE track_id = ?", [.integer(trackID)])
        return count
    }

    /// 统计用：该曲目有没有字幕
    public func hasActiveSubtitles(trackID: Int64) throws -> Bool {
        (try db.queryInt(
            "SELECT COUNT(*) FROM subtitle_track WHERE track_id = ? AND is_active = 1",
            [.integer(trackID)]
        ) ?? 0) > 0
    }
}

public enum SubtitleHistoryFailure: LocalizedError {
    case invalidVersionNumber, cleanupChanged, versionUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidVersionNumber: return InterfaceLocalization.text("字幕版本编号必须递增，请刷新后重试。")
        case .cleanupChanged: return InterfaceLocalization.text("字幕历史未能完整清理，已保留原有记录，请重试。")
        case .versionUnavailable: return InterfaceLocalization.text("当前字幕版本已变更，请刷新后重试。")
        }
    }
}

public enum ScriptImportFailure: LocalizedError {
    case noSelection
    case duplicateTrack
    case emptySection

    public var errorDescription: String? {
        switch self {
        case .noSelection: return InterfaceLocalization.text("请至少为一段台本选择曲目")
        case .duplicateTrack: return InterfaceLocalization.text("多段台本选中了同一曲目，请为每段选择不同曲目")
        case .emptySection: return InterfaceLocalization.text("台本段落里没有可保存的文字")
        }
    }
}

public enum SubtitleInsertFailure: LocalizedError {
    case versionChanged, invalidRow
    public var errorDescription: String? {
        switch self {
        case .versionChanged: return InterfaceLocalization.text("字幕版本已变更，请重新打开当前版本后添加。")
        case .invalidRow: return InterfaceLocalization.text("这行字幕已变更，请重新选择添加位置。")
        }
    }
}
