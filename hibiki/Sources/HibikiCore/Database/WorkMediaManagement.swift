import Foundation

extension WorkCategory {
    public static let attachments = WorkCategory(key: "attachments", title: "作品附件", sortOrder: 6, isBuiltin: true)
}

public struct WorkAttachmentRecord: Identifiable, Equatable, Sendable {
    public var id: Int64
    public let workID: Int64
    public let attachment: WorkAttachment
    public var assetRelativePath: String?
    public var categoryKey: String
    public var sortOrder: Int

    public init(workID: Int64, attachment: WorkAttachment, assetRelativePath: String? = nil,
                id: Int64 = 0, categoryKey: String = WorkCategory.attachments.key, sortOrder: Int = 0) {
        self.workID = workID
        self.attachment = attachment
        self.assetRelativePath = assetRelativePath
        self.id = id
        self.categoryKey = categoryKey
        self.sortOrder = sortOrder
    }
}

public enum WorkMediaID: Codable, Hashable, Sendable {
    case track(Int64), attachment(Int64)
}

public enum WorkMediaItem: Identifiable, Sendable {
    case track(TrackRecord), attachment(WorkAttachmentRecord)
    public var id: WorkMediaID {
        switch self {
        case .track(let track): return .track(track.id)
        case .attachment(let record): return .attachment(record.id)
        }
    }
    var categoryKey: String {
        switch self {
        case .track(let track): return track.effectiveCategoryKey
        case .attachment(let record): return record.categoryKey
        }
    }
    var order: Int {
        switch self {
        case .track(let track): return track.sortOrder
        case .attachment(let record): return record.sortOrder
        }
    }
    public var title: String {
        switch self {
        case .track(let track): return track.displayTitle
        case .attachment(let record): return record.attachment.fileName
        }
    }
}

public struct WorkMediaSection: Identifiable, Sendable {
    public var id: String { category.key }
    public let category: WorkCategory
    public var items: [WorkMediaItem]
}

extension LibraryRepository {
    public func attachmentRecords(workID: Int64) throws -> [WorkAttachmentRecord] {
        try db.query("SELECT * FROM work_attachment WHERE work_id = ? ORDER BY sort_order, id",
                     [.integer(workID)]).compactMap { row in
            guard let id = row.int64("id"), let path = row.string("relative_path"),
                  let kind = row.string("kind").flatMap(WorkAttachmentKind.init(rawValue:)) else { return nil }
            let file = WorkAttachment(relativePath: path, kind: kind, byteCount: row.int64("byte_count") ?? 0)
            return WorkAttachmentRecord(workID: workID, attachment: file, assetRelativePath: row.string("asset_relative_path"),
                                        id: id, categoryKey: row.string("category_key") ?? WorkCategory.attachments.key,
                                        sortOrder: row.int("sort_order") ?? 0)
        }
    }

    func excludedFiles(workID: Int64, kind: String) throws -> Set<String> {
        Set(try db.query("SELECT relative_path FROM excluded_work_file WHERE work_id = ? AND kind = ?",
                         [.integer(workID), .text(kind)]).compactMap { $0.string("relative_path") })
    }

    public func replaceScannedAttachments(workID: Int64, files: [WorkAttachment]) throws {
        try db.transaction {
            guard try work(id: workID) != nil else { throw LibraryEditingError.missingWork }
            let excluded = try excludedFiles(workID: workID, kind: "attachment")
            let existing = try attachmentRecords(workID: workID)
            var byPath = Dictionary(uniqueKeysWithValues: existing.filter { $0.assetRelativePath == nil }.map { ($0.attachment.relativePath, $0) })
            var order = try nextMediaOrder(workID: workID)
            for file in files where !excluded.contains(file.relativePath) {
                if let previous = byPath.removeValue(forKey: file.relativePath) {
                    if previous.attachment != file {
                        try db.execute("UPDATE work_attachment SET kind = ?, byte_count = ? WHERE id = ?",
                                       [.text(file.kind.rawValue), .integer(file.byteCount), .integer(previous.id)])
                    }
                } else {
                    try insertAttachment(WorkAttachmentRecord(workID: workID, attachment: file), order: order)
                    order += 1
                }
            }
            for previous in byPath.values {
                try db.execute("DELETE FROM work_attachment WHERE id = ?", [.integer(previous.id)])
            }
        }
    }

    private func insertAttachment(_ record: WorkAttachmentRecord, order: Int) throws {
        let file = record.attachment
        guard LibraryPathResolver.assetPath(relative: file.relativePath, assetsRoot: "/assets") != nil else {
            throw LibraryEditingError.invalidAssetPath
        }
        try db.execute("""
            INSERT INTO work_attachment(work_id, relative_path, kind, byte_count, asset_relative_path, sort_order)
            VALUES (?, ?, ?, ?, ?, ?)
            """, [.integer(record.workID), .text(file.relativePath), .text(file.kind.rawValue),
                  .integer(file.byteCount), .optional(record.assetRelativePath), .integer(order)])
    }

    func nextMediaOrder(workID: Int64) throws -> Int {
        let last = try db.queryInt("""
            SELECT MAX(position) FROM (SELECT MAX(sort_order) AS position FROM track WHERE work_id = ?
                UNION ALL SELECT MAX(sort_order) FROM work_attachment WHERE work_id = ?)
            """, [.integer(workID), .integer(workID)])
        return (last ?? -1) + 1
    }

    public func appendOwnedMedia(workID: Int64, tracks: [TrackRecord], attachments: [WorkAttachmentRecord]) throws {
        try db.transaction {
            try appendOwnedTracks(workID: workID, tracks: tracks)
            let next = try nextMediaOrder(workID: workID)
            for (offset, record) in attachments.enumerated() {
                guard record.workID == workID, let path = record.assetRelativePath,
                      LibraryPathResolver.assetPath(relative: path, assetsRoot: "/assets") != nil else {
                    throw LibraryEditingError.invalidAssetPath
                }
                try insertAttachment(record, order: next + offset)
            }
        }
    }

    public func organizedSections(workID: Int64, includeEmpty: Bool = false) throws -> [WorkMediaSection] {
        let files = try attachmentRecords(workID: workID).map(WorkMediaItem.attachment)
        let media = try tracks(workID: workID).map(WorkMediaItem.track) + files
        var groups = Dictionary(grouping: media, by: \.categoryKey)
        var sections: [WorkMediaSection] = []
        func add(_ category: WorkCategory) {
            // Keep original track order for a v12 library with equal sort_order values.
            let items = (groups.removeValue(forKey: category.key) ?? []).sorted { $0.order < $1.order }
            if includeEmpty || !items.isEmpty || !category.isBuiltin {
                sections.append(WorkMediaSection(category: category, items: items))
            }
        }
        for category in try categories(workID: workID) { add(category) }
        for key in groups.keys.sorted() { add(WorkCategory(key: key, title: key, sortOrder: Int.max, isBuiltin: true)) }
        return sections
    }

    public func moveMedia(workID: Int64, item: WorkMediaID, to category: String,
                          relativeTo neighbor: WorkMediaID?, after: Bool) throws {
        let snapshot = WorkReorderSnapshot(workID: workID, sections: try organizedSections(workID: workID, includeEmpty: true))
        // Keep the legacy nil-neighbor meaning (group start); new callers can
        // explicitly choose groupEnd instead of overloading a Boolean.
        let destination: WorkDropDestination = neighbor.map { .item(category: category, neighbor: $0, after: after) }
            ?? .groupStart(category)
        _ = try applyReorder(payload: WorkReorderPayload(workID: workID, content: .item(item)),
                             to: destination, expected: snapshot)
    }

    /// Uses the same plan as the insertion indicator. A stale asynchronous drop
    /// is rejected before any category or order value is changed.
    /// Returns false for a valid no-op, true only when data changed.
    @discardableResult
    public func applyReorder(payload: WorkReorderPayload, to destination: WorkDropDestination,
                              expected: WorkReorderSnapshot) throws -> Bool {
        try db.transaction {
            guard payload.workID == expected.workID else { throw LibraryEditingError.staleTrackOrder }
            guard try work(id: expected.workID) != nil else { throw LibraryEditingError.missingWork }
            let current = WorkReorderSnapshot(workID: expected.workID,
                sections: try organizedSections(workID: expected.workID, includeEmpty: true))
            guard current == expected else { throw LibraryEditingError.staleTrackOrder }
            let plan = try WorkReorderPlanner.plan(payload: payload, to: destination, in: current)
            switch plan {
            case .unchanged: return false
            case .groups(let keys):
                try saveCategoryOrder(workID: expected.workID, keys: keys)
                return true
            case .item(let item, let category, let ids):
                try applyMediaOrder(workID: expected.workID, item: item, category: category, ids: ids)
                return true
            }
        }
    }

    private func applyMediaOrder(workID: Int64, item: WorkMediaID, category: String, ids: [WorkMediaID]) throws {
        for (order, id) in ids.enumerated() {
            switch id {
            case .track(let trackID):
                if id == item {
                    try setCategoryOverride(workID: workID, trackIDs: [trackID], key: category)
                }
                try db.execute("UPDATE track SET sort_order = ? WHERE work_id = ? AND id = ?",
                               [.integer(order), .integer(workID), .integer(trackID)])
            case .attachment(let attachmentID):
                try db.execute("UPDATE work_attachment SET sort_order = ?, category_key = ? WHERE work_id = ? AND id = ?",
                               [.integer(order), .text(category), .integer(workID), .integer(attachmentID)])
            }
        }
    }

    func saveCategoryOrder(workID: Int64, keys: [String]) throws {
        let json = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        try db.execute("UPDATE work SET category_order = ? WHERE id = ?", [.text(json), .integer(workID)])
    }

    public func reorderCategories(workID: Int64, keys: [String]) throws {
        try db.transaction {
            let existing = try categories(workID: workID)
            guard existing.count == keys.count, Set(existing.map(\.key)) == Set(keys) else {
                throw LibraryEditingError.staleTrackOrder
            }
            try saveCategoryOrder(workID: workID, keys: keys)
        }
    }

    /// Only explicitly removed source files are excluded from future discovery.
    public func removeMedia(workID: Int64, id: WorkMediaID) throws -> String? {
        try db.transaction {
            let relative: String?, owned: String?, kind: String
            switch id {
            case .track(let trackID):
                guard let track = try track(id: trackID), track.workID == workID else { throw LibraryEditingError.staleTrackOrder }
                if let folder = try work(id: workID)?.folderPath, track.filePath.hasPrefix(folder + "/") {
                    relative = String(track.filePath.dropFirst(folder.count + 1))
                } else {
                    relative = track.relativePath ?? track.fileName
                }
                owned = track.assetRelativePath
                kind = "track"
                try db.execute("DELETE FROM playlist_entry WHERE track_id = ? AND clip_filename IS NULL", [.integer(trackID)])
                try db.execute("UPDATE work SET last_played_track_id = NULL, last_played_position = 0 WHERE id = ? AND last_played_track_id = ?",
                               [.integer(workID), .integer(trackID)])
                try db.execute("DELETE FROM track WHERE id = ?", [.integer(trackID)])
            case .attachment(let fileID):
                guard let file = try attachmentRecords(workID: workID).first(where: { $0.id == fileID }) else { throw LibraryEditingError.staleTrackOrder }
                relative = file.attachment.relativePath
                owned = file.assetRelativePath
                kind = "attachment"
                try db.execute("DELETE FROM work_attachment WHERE id = ? AND work_id = ?", [.integer(fileID), .integer(workID)])
            }
            if owned == nil, let relative {
                try db.execute("INSERT OR IGNORE INTO excluded_work_file(work_id, kind, relative_path) VALUES (?, ?, ?)",
                               [.integer(workID), .text(kind), .text(relative)])
            }
            return owned
        }
    }

    public func removeWorkFromLibrary(workID: Int64) throws -> [String] {
        try db.transaction {
            guard let work = try work(id: workID) else { throw LibraryEditingError.missingWork }
            let owned = try tracks(workID: workID).compactMap(\.assetRelativePath)
                + attachmentRecords(workID: workID).compactMap(\.assetRelativePath) + [work.coverAssetPath].compactMap { $0 }
            try db.execute("INSERT OR IGNORE INTO excluded_source_work(source_id, folder_rel) VALUES (?, ?)",
                           [.integer(work.sourceID), .text(work.folderRelativePath)])
            try db.execute("DELETE FROM playlist_entry WHERE clip_filename IS NULL AND track_id IN (SELECT id FROM track WHERE work_id = ?)",
                           [.integer(workID)])
            try deleteWork(id: workID)
            return owned
        }
    }

    public func excludedWorkPaths(sourceID: Int64) throws -> Set<String> {
        Set(try db.query("SELECT folder_rel FROM excluded_source_work WHERE source_id = ?", [.integer(sourceID)])
            .compactMap { $0.string("folder_rel") })
    }

    public func restoreExplicitWork(sourceID: Int64, folder: String) throws {
        try db.execute("DELETE FROM excluded_source_work WHERE source_id = ? AND folder_rel = ?", [.integer(sourceID), .text(folder)])
    }
}
