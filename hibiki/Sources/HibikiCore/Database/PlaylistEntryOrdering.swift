import Foundation

extension PlaylistRepository {
    /// Reject an outdated drag snapshot rather than overwriting a changed collection.
    public func orderEntries(groupID: Int64, ids: [Int64], expectedIDs: [Int64]) throws {
        try db.transaction {
            guard db.userVersion >= 26,
                  try db.queryInt("SELECT 1 FROM playlist_group WHERE id = ?", [.integer(groupID)]) == 1 else {
                throw PlaylistCollectionError.invalidGroup
            }
            let current = try entryIDs(groupID: groupID)
            guard current == expectedIDs, ids.count == current.count,
                  Set(ids) == Set(current) else { throw PlaylistCollectionError.staleEntries }
            for (index, id) in ids.enumerated() {
                try db.execute("UPDATE playlist_entry SET sort_order = ? WHERE id = ? AND group_id = ?",
                               [.integer(index), .integer(id), .integer(groupID)])
            }
        }
    }

    /// Move the existing row, retaining its audio file, captured subtitles and identity.
    /// Whole media already present in the destination is explicitly rejected, never deleted.
    public func moveEntry(id: Int64, from sourceID: Int64, to targetID: Int64) throws {
        try db.transaction {
            guard let row = try db.query("SELECT * FROM playlist_entry WHERE id = ? AND group_id = ?",
                                        [.integer(id), .integer(sourceID)]).first else {
                throw PlaylistCollectionError.staleEntries
            }
            let isClip = row.string("clip_filename") != nil
            guard try db.queryInt("SELECT 1 FROM playlist_group WHERE id = ? AND is_clips = ?",
                                  [.integer(targetID), .integer(isClip)]) == 1 else {
                throw PlaylistCollectionError.invalidGroup
            }
            guard sourceID != targetID else { return }
            if !isClip {
                for column in ["track_id", "attachment_id"] {
                    guard let mediaID = row.int64(column) else { continue }
                    if try db.queryInt("SELECT 1 FROM playlist_entry WHERE group_id = ? AND \(column) = ? AND clip_filename IS NULL",
                                       [.integer(targetID), .integer(mediaID)]) == 1 {
                        throw PlaylistCollectionError.duplicateEntry
                    }
                }
            }
            try appendEntries([id], to: targetID)
        }
    }

    func entryIDs(groupID: Int64) throws -> [Int64] {
        let order = db.userVersion >= 26 ? "sort_order, id" : "id"
        return try db.query("SELECT id FROM playlist_entry WHERE group_id = ? ORDER BY \(order)",
                            [.integer(groupID)]).compactMap { $0.int64("id") }
    }

    /// Called inside a transaction, including when removing a collection. Source order
    /// is appended to the destination so its existing custom order does not interleave.
    func appendEntries(_ ids: [Int64], to targetID: Int64) throws {
        if db.userVersion >= 26 {
            let start = try db.queryInt("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM playlist_entry WHERE group_id = ?",
                                       [.integer(targetID)]) ?? 0
            for (offset, id) in ids.enumerated() {
                try db.execute("UPDATE playlist_entry SET group_id = ?, sort_order = ? WHERE id = ?",
                               [.integer(targetID), .integer(start + offset), .integer(id)])
            }
        } else {
            for id in ids {
                try db.execute("UPDATE playlist_entry SET group_id = ? WHERE id = ?", [.integer(targetID), .integer(id)])
            }
        }
    }
}
