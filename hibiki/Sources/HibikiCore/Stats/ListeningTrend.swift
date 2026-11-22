import Foundation

/// Fills silent days between observations so the horizontal distance represents elapsed time.
public struct ListeningTrend {
    public let granularity: TrendGranularity
    public let points: [TrendPoint]

    public init(rows: [PlayStatRow], period: StatPeriod, now: Date, calendar: Calendar) {
        let keys = rows.map(\.dateKey)
        let range = period.dateKeyRange(now: now, calendar: calendar)
        let today = PlaybackStatSplitter.dateKey(from: now, calendar: calendar)
        guard !rows.isEmpty, let startKey = range?.from ?? keys.min(),
              let endKey = range?.to ?? keys.max(),
              let start = StatsAggregator.parseDateKey(startKey, calendar: calendar),
              let end = StatsAggregator.parseDateKey(min(endKey, today), calendar: calendar),
              start <= end else {
            granularity = .day
            points = []
            return
        }
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        let step: Calendar.Component
        if period == .thisYear || days > 120 {
            granularity = .month
            step = .month
        } else if days > 31 {
            granularity = .week
            step = .weekOfYear
        } else {
            granularity = .day
            step = .day
        }
        let totals = StatsAggregator.trend(rows, granularity: granularity, calendar: calendar)
        let values = Dictionary(uniqueKeysWithValues: totals.map { ($0.bucketKey, $0.seconds) })
        var cursor = calendar.dateInterval(of: step, for: start)?.start ?? start
        var result: [TrendPoint] = []
        while cursor <= end {
            let date = PlaybackStatSplitter.dateKey(from: cursor, calendar: calendar)
            let key = StatsAggregator.bucketKey(for: date, granularity: granularity, calendar: calendar)
            result.append(TrendPoint(bucketKey: key, seconds: values[key] ?? 0, label: StatsAggregator.bucketLabel(key)))
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        points = result
    }
}
