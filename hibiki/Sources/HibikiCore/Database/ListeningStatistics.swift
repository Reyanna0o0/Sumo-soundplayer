import Foundation

/// 明细以每个会话一行返回；seconds 是该次播放已经持久化的总秒数。
public typealias ListeningHistoryEntry = ListeningSessionDelta

extension PlaybackStatSplitter {
    /// 存储与查询使用同一公历日键，随设备所在时区划分日期与小时。
    public static var listeningCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.current.firstWeekday
        calendar.minimumDaysInFirstWeek = Calendar.current.minimumDaysInFirstWeek
        return calendar
    }
}

extension LibraryRepository {
    /// 每次结算是一个事务，写入中途失败时调用方可以安全地重试整批。
    public func recordListening(_ rows: [PlayStatRow], sessions: [ListeningSessionDelta] = []) throws {
        guard !rows.isEmpty || !sessions.isEmpty else { return }
        let hasLibraries = db.userVersion >= 17
        let libraryColumns = hasLibraries ? ", library_kind, creator_id, creator_name" : ""
        let libraryValues = hasLibraries ? ", ?, ?, ?" : ""
        try db.transaction {
            for row in rows {
                let names = String(decoding: try JSONEncoder().encode(row.seiyuuNames), as: UTF8.self)
                let personal = row.workID > 0 && row.libraryKind == .personal
                let libraryParams: [SQLValue] = hasLibraries
                    ? [.optional(row.workID > 0 ? row.libraryKind?.rawValue : nil),
                       personal ? row.creatorID.map(SQLValue.integer) ?? .null : .null,
                       .optional(personal ? row.creatorName : nil)] : []
                try db.execute("""
                    INSERT INTO play_statistic (date_key, hour_slot, work_id, seconds, title, circle_name, seiyuu_names\(libraryColumns))
                    VALUES (?, ?, ?, ?, ?, ?, ?\(libraryValues))
                    ON CONFLICT(date_key, hour_slot, work_id) DO UPDATE SET
                        seconds = play_statistic.seconds + excluded.seconds
                    """, [.text(row.dateKey), .optional(row.hourSlot), .integer(row.workID), .integer(row.seconds),
                          .optional(row.title), .optional(row.circleName), .text(names)] + libraryParams)
            }
            for session in sessions {
                let libraryParams: [SQLValue] = hasLibraries
                    ? [.optional(session.libraryKind?.rawValue), session.creatorID.map(SQLValue.integer) ?? .null,
                       .optional(session.creatorName)] : []
                try db.execute("""
                    INSERT INTO play_history (session_id, started_at, start_date_key, start_time_zone_id, work_id,
                                              track_id, work_title, track_title, is_saved_clip, seconds\(libraryColumns))
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?\(libraryValues))
                    ON CONFLICT(session_id) DO UPDATE SET seconds = play_history.seconds + excluded.seconds
                    """, [.text(session.id.uuidString), SQLValue(session.startedAt), .text(session.startDateKey),
                          .text(session.startTimeZoneID), .integer(session.workID), .integer(session.trackID),
                          .text(session.workTitle), .text(session.trackTitle), .integer(session.isSavedClip),
                          .integer(session.seconds)] + libraryParams)
            }
        }
    }

    /// Reports offer only periods with records, plus the current calendar period.
    public func listeningMonthKeys(libraryKind: MediaLibraryKind? = nil) throws -> [String] {
        let predicate = libraryKind == nil ? "" : "WHERE COALESCE(w.library_kind, s.library_kind) = ?"
        return try db.query("""
            SELECT DISTINCT substr(s.date_key, 1, 7) AS month FROM play_statistic s
            LEFT JOIN work w ON w.id = s.work_id \(predicate) ORDER BY month DESC
            """, libraryKind.map { [.text($0.rawValue)] } ?? [])
            .compactMap { $0.string("month") }
    }

    public func listeningRows(period: StatPeriod, now: Date = Date(),
                              calendar: Calendar = PlaybackStatSplitter.listeningCalendar,
                              libraryKind: MediaLibraryKind? = nil) throws -> [PlayStatRow] {
        let range = period.dateKeyRange(now: now, calendar: calendar)
        var conditions = range == nil ? [] : ["s.date_key BETWEEN ? AND ?"]
        var params: [SQLValue] = range.map { [.text($0.from), .text($0.to)] } ?? []
        if let libraryKind {
            conditions.append("COALESCE(w.library_kind, s.library_kind) = ?")
            params.append(.text(libraryKind.rawValue))
        }
        let predicate = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let result = try db.query("""
            SELECT s.rowid AS id, s.work_id, s.date_key, s.hour_slot, s.seconds,
                   COALESCE(w.title_override, w.title, s.title) AS title,
                   CASE WHEN w.id IS NULL THEN s.circle_name
                        ELSE COALESCE(w.circle_name_override, w.circle_name) END AS circle_name,
                   CASE WHEN w.id IS NULL THEN s.seiyuu_names ELSE w.seiyuu_names_override END AS seiyuu_names,
                   CASE WHEN w.id IS NULL THEN s.scanned_seiyuu ELSE w.seiyuu_name END AS scanned_seiyuu,
                   COALESCE(w.library_kind, s.library_kind) AS library_kind,
                   CASE WHEN w.id IS NULL THEN s.creator_id ELSE w.creator_id END AS creator_id,
                   CASE WHEN w.id IS NULL THEN s.creator_name ELSE c.name END AS creator_name
            FROM play_statistic s LEFT JOIN work w ON w.id = s.work_id
            LEFT JOIN creator c ON c.id = w.creator_id
            \(predicate)
            ORDER BY s.date_key, s.hour_slot, s.work_id
            """, params)
        return result.map { row in
            let names = row.string("seiyuu_names").flatMap {
                try? JSONDecoder().decode([String].self, from: Data($0.utf8))
            }
            let kind = row.string("library_kind").flatMap(MediaLibraryKind.init(rawValue:))
            let creatorName = row.string("creator_name")
            let personalNames = kind == .personal ? creatorName.map { [$0] } ?? [] : nil
            return PlayStatRow(id: row.int64("id")!, workID: row.int64("work_id")!,
                               title: row.string("title"), seiyuuName: row.string("scanned_seiyuu"),
                               seiyuuNames: personalNames ?? names, circleName: kind == .personal ? creatorName : row.string("circle_name"),
                               dateKey: row.string("date_key")!, hourSlot: row.int("hour_slot"),
                               seconds: row.int("seconds")!, libraryKind: kind,
                               creatorID: row.int64("creator_id"), creatorName: creatorName)
        }
    }

    public func listeningHistory(period: StatPeriod, limit: Int, now: Date = Date(),
                                 calendar: Calendar = PlaybackStatSplitter.listeningCalendar,
                                 libraryKind: MediaLibraryKind? = nil) throws -> [ListeningHistoryEntry] {
        guard limit > 0 else { return [] }
        let range = period.dateKeyRange(now: now, calendar: calendar)
        var conditions = range == nil ? [] : ["h.start_date_key BETWEEN ? AND ?"]
        var bounds: [SQLValue] = range.map { [.text($0.from), .text($0.to)] } ?? []
        if let libraryKind {
            conditions.append("COALESCE(w.library_kind, h.library_kind) = ?")
            bounds.append(.text(libraryKind.rawValue))
        }
        let predicate = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let rows = try db.query("""
            SELECT h.*, COALESCE(w.library_kind, h.library_kind) AS effective_library_kind,
                   CASE WHEN w.id IS NULL THEN h.creator_id ELSE w.creator_id END AS effective_creator_id,
                   CASE WHEN w.id IS NULL THEN h.creator_name ELSE c.name END AS effective_creator_name
            FROM play_history h LEFT JOIN work w ON w.id = h.work_id
            LEFT JOIN creator c ON c.id = w.creator_id
            \(predicate) ORDER BY h.started_at DESC, h.session_id LIMIT ?
            """, bounds + [.integer(limit)])
        return rows.map { row in
            ListeningHistoryEntry(id: UUID(uuidString: row.string("session_id")!)!,
                                  startedAt: row.date("started_at")!, startDateKey: row.string("start_date_key")!,
                                  startTimeZoneID: row.string("start_time_zone_id")!, workID: row.int64("work_id")!,
                                  trackID: row.int64("track_id")!, workTitle: row.string("work_title")!,
                                  trackTitle: row.string("track_title")!, isSavedClip: row.bool("is_saved_clip"),
                                  seconds: row.int("seconds")!,
                                  libraryKind: row.string("effective_library_kind").flatMap(MediaLibraryKind.init(rawValue:)),
                                  creatorID: row.int64("effective_creator_id"), creatorName: row.string("effective_creator_name"))
        }
    }
}
