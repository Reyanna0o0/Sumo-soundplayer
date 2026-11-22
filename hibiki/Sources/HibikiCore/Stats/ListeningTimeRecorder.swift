import Foundation

/// 一次连续收听的元数据和待结算秒数。trackID 为负值时指向独立保存的摘选。
public struct ListeningSessionDelta: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let startDateKey: String
    public let startTimeZoneID: String
    public let workID: Int64
    public let trackID: Int64
    public let workTitle: String
    public let trackTitle: String
    public let isSavedClip: Bool
    public let libraryKind: MediaLibraryKind?
    public let creatorID: Int64?
    public let creatorName: String?
    public var seconds: Int

    public init(id: UUID = UUID(), startedAt: Date, startDateKey: String? = nil,
                startTimeZoneID: String = TimeZone.current.identifier, workID: Int64, trackID: Int64,
                workTitle: String, trackTitle: String, isSavedClip: Bool, seconds: Int = 0,
                libraryKind: MediaLibraryKind? = .collection, creatorID: Int64? = nil, creatorName: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.startTimeZoneID = startTimeZoneID
        var calendar = PlaybackStatSplitter.listeningCalendar
        if let zone = TimeZone(identifier: startTimeZoneID) { calendar.timeZone = zone }
        self.startDateKey = startDateKey ?? PlaybackStatSplitter.dateKey(from: startedAt, calendar: calendar)
        self.workID = workID
        self.trackID = trackID
        self.workTitle = workTitle
        self.trackTitle = trackTitle
        self.isSavedClip = isSavedClip
        self.seconds = seconds
        self.libraryKind = workID > 0 ? libraryKind : nil
        self.creatorID = workID > 0 && libraryKind == .personal ? creatorID : nil
        self.creatorName = workID > 0 && libraryKind == .personal ? creatorName : nil
    }
}

/// 日期用于决定归属的小时；时长来自连续走时的钟，与音轨进度、倍速或系统校时无关。
public struct ListeningTimeRecorder {
    private struct Session {
        let work: PlayStatRow
        let detail: ListeningSessionDelta
        let date: Date
        let uptime: TimeInterval
    }

    private struct Bucket: Hashable {
        let workID: Int64
        let day: String
        let hour: Int
    }

    private var session: Session?
    private var pending: [Bucket: PlayStatRow] = [:]
    private var pendingSessions: [UUID: ListeningSessionDelta] = [:]
    private var fractionalSeconds: [Int64: TimeInterval] = [:]
    public var isRunning: Bool { session != nil }

    public init() {}

    public mutating func start(work: PlayStatRow, detail: ListeningSessionDelta, uptime: TimeInterval) {
        guard session == nil else { return }
        session = Session(work: work, detail: detail, date: detail.startedAt, uptime: uptime)
    }

    public mutating func checkpoint(date: Date, uptime: TimeInterval, continuing: Bool, calendar: Calendar) {
        guard let current = session else { return }
        session = continuing ? Session(work: current.work, detail: current.detail, date: date, uptime: uptime) : nil
        let elapsed = max(0, uptime - current.uptime)
        let end = current.date.addingTimeInterval(elapsed)
        PlaybackStatSplitter.forEachHour(start: current.date, end: end, calendar: calendar) { day, hour, interval in
            let workID = current.work.workID
            // 快速暂停或频繁打开统计页也保留小数；凑满一秒才写库。
            let total = interval + (fractionalSeconds[workID] ?? 0)
            let whole = Int(total)
            fractionalSeconds[workID] = total - Double(whole)
            guard whole > 0 else { return }
            let key = Bucket(workID: workID, day: day, hour: hour)
            var row = current.work
            row.dateKey = day
            row.hourSlot = hour
            row.seconds = (pending[key]?.seconds ?? 0) + whole
            pending[key] = row
            var detail = current.detail
            detail.seconds = (pendingSessions[detail.id]?.seconds ?? 0) + whole
            pendingSessions[detail.id] = detail
        }
    }

    /// 写入端需要以事务保存整批；只有成功后才清除，断开存储后可重试。
    public mutating func save(using write: ([PlayStatRow], [ListeningSessionDelta]) throws -> Void) rethrows {
        guard !pending.isEmpty else { return }
        try write(Array(pending.values), Array(pendingSessions.values))
        pending.removeAll(keepingCapacity: true)
        pendingSessions.removeAll(keepingCapacity: true)
    }
}
