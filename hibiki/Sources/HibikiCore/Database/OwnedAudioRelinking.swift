import Foundation

public enum OwnedAudioRelinkingError: LocalizedError, Equatable {
    case unavailable, staleSelection, invalidAudio, alreadyFinished

    public var errorDescription: String? {
        switch self {
        case .unavailable: return InterfaceLocalization.text("这条个人音声已不在原作品中，请返回后重新选择。")
        case .staleSelection: return InterfaceLocalization.text("原音频资料或位置在选择期间发生了变化，本次未替换，请重新选择音频。")
        case .invalidAudio: return InterfaceLocalization.text("新音频副本无法读取或已发生变化，请重新选择。")
        case .alreadyFinished: return InterfaceLocalization.text("这次音频选择已处理，请重新选择音频。")
        }
    }
}

/// Captures exact persisted values, including columns not exposed by TrackRecord.
public struct OwnedAudioRelinkSnapshot: Equatable, Sendable {
    public let track: TrackRecord
    public let work: WorkRecord
    fileprivate let trackRow: SQLRow
    fileprivate let workRow: SQLRow
    fileprivate let sourceRow: SQLRow
}

/// Typed archival values retain Int64 IDs, nulls and source bookmarks exactly.
/// Kept inside the existing app_setting table; no schema migration is needed.
public enum OwnedAudioArchiveValue: Codable, Equatable, Sendable {
    case null, integer(Int64), real(Double), text(String), blob(Data)

    init(_ value: SQLValue) {
        switch value {
        case .null: self = .null
        case .integer(let value): self = .integer(value)
        case .real(let value): self = .real(value)
        case .text(let value): self = .text(value)
        case .blob(let value): self = .blob(value)
        }
    }

    var sqlValue: SQLValue {
        switch self {
        case .null: return .null
        case .integer(let value): return .integer(value)
        case .real(let value): return .real(value)
        case .text(let value): return .text(value)
        case .blob(let value): return .blob(value)
        }
    }
}

public struct OwnedAudioArchivedRow: Codable, Equatable, Sendable {
    public let values: [String: OwnedAudioArchiveValue]
    init(_ row: SQLRow) { values = row.values.mapValues(OwnedAudioArchiveValue.init) }
    public var sqlRow: SQLRow { SQLRow(values.mapValues(\.sqlValue)) }
}

public struct OwnedAudioRelinkHistory: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let operationID: UUID
    public let changedAt: Date
    public let workID: Int64
    public let trackID: Int64
    public let previousTrack: OwnedAudioArchivedRow
    public let previousWork: OwnedAudioArchivedRow
    public let previousSource: OwnedAudioArchivedRow
    public let replacementTrack: OwnedAudioArchivedRow
}

extension LibraryRepository {
    public func ownedAudioRelinkSnapshot(workID: Int64, trackID: Int64) throws -> OwnedAudioRelinkSnapshot {
        guard db.userVersion >= 13,
              let work = try work(id: workID), work.libraryKind == .personal,
              let track = try track(id: trackID), track.workID == workID, !track.isVideo,
              let trackRow = try db.query("SELECT * FROM track WHERE id = ?", [.integer(trackID)]).first,
              let workRow = try db.query("SELECT * FROM work WHERE id = ?", [.integer(workID)]).first,
              let sourceRow = try db.query("SELECT * FROM source WHERE id = ?", [.integer(work.sourceID)]).first else {
            throw OwnedAudioRelinkingError.unavailable
        }
        return OwnedAudioRelinkSnapshot(track: track, work: work, trackRow: trackRow,
                                       workRow: workRow, sourceRow: sourceRow)
    }

    /// A confirmed replacement changes only the source-file columns on the
    /// existing track. Dependants, edits, ordering and playback history keep IDs.
    /// The caller validates/copies audio first and owns cleanup until this succeeds.
    @discardableResult
    public func replaceOwnedAudio(expected: OwnedAudioRelinkSnapshot, with replacement: TrackRecord,
                                  operationID: UUID) throws -> TrackRecord {
        let supported = Set(["mp3", "m4a", "m4b", "aac", "wav", "wave", "aiff", "aif", "flac", "caf"])
        guard replacement.workID == expected.work.id, !replacement.isVideo,
              supported.contains(replacement.fileType.lowercased()),
              let asset = replacement.assetRelativePath, asset.hasPrefix("Audio/"),
              LibraryPathResolver.assetPath(relative: asset, assetsRoot: "/assets") != nil,
              (asset as NSString).pathExtension.lowercased() == replacement.fileType.lowercased(),
              replacement.durationMS.map({ $0 > 0 }) == true,
              replacement.fileSize.map({ $0 > 0 }) == true,
              !replacement.fileName.isEmpty, !replacement.fileName.contains("\0"),
              asset != expected.track.assetRelativePath else { throw OwnedAudioRelinkingError.invalidAudio }
        return try db.transaction {
            let current = try ownedAudioRelinkSnapshot(workID: expected.work.id, trackID: expected.track.id)
            let locationColumns = ["id", "source_id", "folder_path", "folder_rel", "library_kind"]
            guard current.trackRow == expected.trackRow, current.sourceRow == expected.sourceRow,
                  locationColumns.allSatisfy({ current.workRow[$0] == expected.workRow[$0] }) else {
                throw OwnedAudioRelinkingError.staleSelection
            }
            let historyKey = "audioRelink.history.\(expected.track.id).\(operationID.uuidString)"
            guard try setting(historyKey) == nil else { throw OwnedAudioRelinkingError.alreadyFinished }

            if current.track.assetRelativePath == nil {
                // A later folder rescan must not reinsert the retired external
                // source as another track. The file itself remains untouched.
                let prefix = current.work.folderPath.hasSuffix("/") ? current.work.folderPath : current.work.folderPath + "/"
                let relative = current.track.filePath.hasPrefix(prefix)
                    ? String(current.track.filePath.dropFirst(prefix.count))
                    : current.track.relativePath ?? current.track.fileName
                try db.execute("INSERT OR IGNORE INTO excluded_work_file(work_id, kind, relative_path) VALUES (?, 'track', ?)",
                               [.integer(current.work.id), .text(relative)])
            }
            try db.execute("""
                UPDATE track SET file_name = ?, file_path = ?, relative_path = NULL, file_rel = NULL,
                    file_type = ?, duration_ms = ?, file_size = ?, file_mtime = ?, asset_relative_path = ?
                WHERE id = ? AND work_id = ?
                """, [.text(replacement.fileName), .text("app-asset:" + asset), .text(replacement.fileType.lowercased()),
                      .optional(replacement.durationMS), replacement.fileSize.map(SQLValue.integer) ?? .null,
                      replacement.fileMtime.map { SQLValue($0) } ?? .null, .text(asset),
                      .integer(current.track.id), .integer(current.work.id)])
            guard let updated = try track(id: current.track.id),
                  let updatedRow = try db.query("SELECT * FROM track WHERE id = ?", [.integer(current.track.id)]).first else {
                throw OwnedAudioRelinkingError.unavailable
            }
            let history = OwnedAudioRelinkHistory(formatVersion: 1, operationID: operationID, changedAt: Date(),
                workID: current.work.id, trackID: current.track.id,
                previousTrack: OwnedAudioArchivedRow(current.trackRow), previousWork: OwnedAudioArchivedRow(current.workRow),
                previousSource: OwnedAudioArchivedRow(current.sourceRow), replacementTrack: OwnedAudioArchivedRow(updatedRow))
            let json = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
            try setSetting(historyKey, json)
            return updated
        }
    }

    public func ownedAudioRelinkHistory(trackID: Int64) throws -> [OwnedAudioRelinkHistory] {
        try db.query("SELECT value FROM app_setting WHERE key LIKE ? ORDER BY updated_at, key",
                     [.text("audioRelink.history.\(trackID).%")]).map { row in
            guard let json = row.string("value") else { throw OwnedAudioRelinkingError.unavailable }
            return try JSONDecoder().decode(OwnedAudioRelinkHistory.self, from: Data(json.utf8))
        }
    }
}
