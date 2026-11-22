import Foundation

/// 手动翻阅位置与播放时间分开；每个音轨的每份台本各自保留一处位置。
public final class ReadingPositionRepository {
    private let db: SQLiteDatabase

    public init(database: SQLiteDatabase) { db = database }

    public func scriptPosition(subtitleTrackID: Int64) throws -> ScriptReadingPosition? {
        let json = try db.query("SELECT payload FROM subtitle_reading_position WHERE subtitle_track_id = ?",
                                [.integer(subtitleTrackID)]).first?.string("payload")
        guard let value: ScriptReadingPosition = decode(json), value.isValid else { return nil }
        return value
    }

    public func saveScriptPosition(_ position: ScriptReadingPosition, subtitleTrackID: Int64) throws {
        try db.execute("""
            INSERT INTO subtitle_reading_position (subtitle_track_id, payload, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(subtitle_track_id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
            """, [.integer(subtitleTrackID), .text(try encode(position)), SQLValue(Date())])
    }

    public func pdfPosition(attachmentID: Int64) throws -> PDFReadingPosition? {
        guard let value: PDFReadingPosition = try attachmentPosition(attachmentID: attachmentID, kind: "pdf"),
              value.isValid else { return nil }
        return value
    }

    public func savePDFPosition(_ position: PDFReadingPosition, attachmentID: Int64) throws {
        try saveAttachmentPosition(position, attachmentID: attachmentID, kind: "pdf")
    }

    public func textPosition(attachmentID: Int64) throws -> TextReadingPosition? {
        guard let value: TextReadingPosition = try attachmentPosition(attachmentID: attachmentID, kind: "text"),
              value.utf16Offset >= 0 else { return nil }
        return value
    }

    public func saveTextPosition(_ position: TextReadingPosition, attachmentID: Int64) throws {
        try saveAttachmentPosition(position, attachmentID: attachmentID, kind: "text")
    }

    private func attachmentPosition<T: Decodable>(attachmentID: Int64, kind: String) throws -> T? {
        let json = try db.query("SELECT payload FROM attachment_reading_position WHERE attachment_id = ? AND kind = ?",
                                [.integer(attachmentID), .text(kind)]).first?.string("payload")
        return decode(json)
    }

    private func saveAttachmentPosition<T: Encodable>(_ value: T, attachmentID: Int64, kind: String) throws {
        try db.execute("""
            INSERT INTO attachment_reading_position (attachment_id, kind, payload, updated_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(attachment_id, kind) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at
            """, [.integer(attachmentID), .text(kind), .text(try encode(value)), SQLValue(Date())])
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// 损坏的旧位置不影响原稿和阅读；真实数据库读写错误仍交给界面处理。
    private func decode<T: Decodable>(_ json: String?) -> T? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
