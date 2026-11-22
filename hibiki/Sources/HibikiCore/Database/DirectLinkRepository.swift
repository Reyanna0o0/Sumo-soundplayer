import Foundation

extension LibraryRepository {
    public func directLinks(workID: Int64) throws -> [DirectLinkMetadata] {
        try db.query("SELECT metadata_json FROM work_direct_link WHERE work_id = ? ORDER BY id", [.integer(workID)])
            .map { row in try JSONDecoder().decode(DirectLinkMetadata.self, from: Data((row.string("metadata_json") ?? "").utf8)) }
    }
    public func workForDirectLink(_ link: DirectLink, library: MediaLibraryKind? = nil) throws -> Int64? {
        var query = "SELECT w.id FROM work_direct_link l JOIN work w ON w.id = l.work_id WHERE l.site = ? AND l.source_url = ?"
        var args: [SQLValue] = [.text(link.site.rawValue), .text(link.url.absoluteString)]
        if let library { query += " AND w.library_kind = ?"; args.append(.text(library.rawValue)) }
        query += " ORDER BY w.id LIMIT 1"
        return try db.query(query, args).first?.int64("id")
    }
    public func saveDirectLink(_ metadata: DirectLinkMetadata, workID: Int64) throws {
        let link = try DirectLink(metadata.sourceURL, site: metadata.site)
        guard link.url.absoluteString == metadata.sourceURL else { throw DirectLinkError.message(InterfaceLocalization.text("来源链接无效。")) }
        let json = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        try db.execute("INSERT INTO work_direct_link(work_id, site, source_url, metadata_json, created_at) VALUES (?, ?, ?, ?, ?)",
            [.integer(workID), .text(metadata.site.rawValue), .text(metadata.sourceURL), .text(json), SQLValue(Date())])
    }
}
