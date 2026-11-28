import Foundation

/// A selected remote audio item. The app owns and validates the encoded locator;
/// the database never treats its address as a local filesystem path.
public struct NetworkImportTrack: Sendable {
    public var name: String
    public var relativePath: String
    public var fileType: String
    public var byteCount: Int64?
    public var modifiedAt: Date?
    public var resourceJSON: String

    public init(name: String, relativePath: String, fileType: String, byteCount: Int64?,
                modifiedAt: Date?, resourceJSON: String) {
        self.name = name; self.relativePath = relativePath; self.fileType = fileType
        self.byteCount = byteCount; self.modifiedAt = modifiedAt; self.resourceJSON = resourceJSON
    }
}

extension LibraryRepository {
    /// Commits source rows and their app-setting records together. No network I/O
    /// may occur inside this synchronous transaction.
    public func networkTransaction<T>(_ changes: () throws -> T) throws -> T {
        try db.transaction(changes)
    }

    /// Imports exactly the user's selected files as one work, with stable IDs.
    /// There is no source-wide scan, replaceTracks, or delete-missing step.
    public func importNetworkWork(sourceID: Int64, title: String, library: MediaLibraryKind,
                                  creatorID: Int64? = nil, coverAssetPath: String? = nil,
                                  tracks: [NetworkImportTrack]) throws -> Int64 {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LibraryEditingError.blankTitle }
        guard !tracks.isEmpty, tracks.count <= 500,
              Set(tracks.map(\.relativePath)).count == tracks.count,
              tracks.allSatisfy({ !$0.name.isEmpty && !$0.relativePath.isEmpty && !$0.resourceJSON.isEmpty }) else {
            throw LibraryEditingError.invalidAssetPath
        }
        return try db.transaction {
            guard let source = try sources(includeDisabled: true).first(where: { $0.id == sourceID }),
                  source.enabled, [.smb, .http, .webdav].contains(source.type) else {
                throw LibraryEditingError.unavailable
            }
            let catalogKey = "network-work:" + UUID().uuidString
            let workID = try upsertWork(WorkRecord(title: title, folderPath: catalogKey,
                folderRelativePath: catalogKey, sourceID: sourceID, libraryKind: library, creatorID: creatorID))
            for (index, track) in tracks.enumerated() {
                // The legacy table has a global UNIQUE(file_path). This opaque key
                // satisfies that constraint without storing a remote URL as a path.
                let key = "network-track:" + UUID().uuidString
                try db.execute("""
                    INSERT INTO track(work_id, file_name, file_path, relative_path, file_rel,
                        file_type, track_index, sort_order, file_size, file_mtime, created_at, category)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'main')
                    """, [.integer(workID), .text(track.name), .text(key), .text(track.relativePath),
                        .text(track.relativePath), .text(track.fileType), .integer(index), .integer(index),
                        track.byteCount.map(SQLValue.integer) ?? .null,
                        track.modifiedAt.map { SQLValue($0) } ?? .null, SQLValue(Date())])
                try setSetting("networkTrack.\(db.lastInsertRowID)", track.resourceJSON)
            }
            if let coverAssetPath { try updateWorkCover(workID: workID, assetRelativePath: coverAssetPath) }
            return workID
        }
    }
}
