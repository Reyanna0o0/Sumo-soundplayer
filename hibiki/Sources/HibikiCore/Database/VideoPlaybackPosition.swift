import Foundation

extension LibraryRepository {
    public func videoPlaybackPosition(attachmentID: Int64) throws -> Int {
        try db.query("SELECT position_ms FROM video_playback_position WHERE attachment_id = ?",
                     [.integer(attachmentID)]).first?.int("position_ms") ?? 0
    }

    public func saveVideoPlaybackPosition(attachmentID: Int64, workID: Int64, positionMS: Int) throws {
        guard positionMS >= 0 else { return }
        try db.transaction {
            guard try db.query("SELECT id FROM work_attachment WHERE id = ? AND work_id = ? AND kind = 'video'",
                               [.integer(attachmentID), .integer(workID)]).first != nil else {
                throw LibraryEditingError.staleTrackOrder
            }
            try db.execute("""
                INSERT INTO video_playback_position (attachment_id, position_ms, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(attachment_id) DO UPDATE SET position_ms = excluded.position_ms, updated_at = excluded.updated_at
                """, [.integer(attachmentID), .integer(Int64(positionMS)), SQLValue(Date())])
            // Audio's last track/position and all edited metadata remain independent.
            try db.execute("UPDATE work SET last_played_at = ? WHERE id = ?", [SQLValue(Date()), .integer(workID)])
        }
    }
}
