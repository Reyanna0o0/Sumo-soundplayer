import SwiftUI
import Charts
import UIKit

/// This display range is independent of the report period selected in the total
/// card. Keep all seven calendar dates, including days with no listening rows.
struct RecentListeningTrend {
    let points: [TrendPoint]

    init(rows: [PlayStatRow], now: Date, calendar: Calendar = PlaybackStatSplitter.listeningCalendar) {
        let scoped = StatPeriod.lastDays(7).filter(rows, now: now, calendar: calendar)
        let totals = StatsAggregator.trend(scoped, granularity: .day, calendar: calendar)
        let seconds = Dictionary(uniqueKeysWithValues: totals.map { ($0.bucketKey, $0.seconds) })
        let today = calendar.startOfDay(for: now)
        points = (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let key = PlaybackStatSplitter.dateKey(from: date, calendar: calendar)
            return TrendPoint(bucketKey: key, seconds: seconds[key] ?? 0, label: StatsAggregator.bucketLabel(key))
        }
    }

    static func duration(_ seconds: Int) -> String { listeningDuration(seconds) }
}

struct SevenDayListeningTrendView: View {
    let points: [TrendPoint]
    @State private var selectedKey: String?

    private var selectedPoint: TrendPoint? { points.first { $0.bucketKey == selectedKey } }

    private var trendInk: Color { AppTheme.painted(.blue, AppTheme.accent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("收听趋势").font(.headline).foregroundStyle(AppTheme.headingInk())
                Spacer()
                Text("最近 7 天 · 分钟").font(.caption).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("statsTrendPeriod")
            }
            Text(selectedPoint.map { "\($0.label) · \(RecentListeningTrend.duration($0.seconds))" }
                 ?? L10n.text("点按或横向滑动查看时长"))
                .font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(selectedPoint == nil ? AppTheme.secondary : trendInk)
                .accessibilityIdentifier("statsTrendSelection")
            Chart(points) { point in
                BarMark(x: .value(L10n.text("日期"), point.bucketKey), y: .value(L10n.text("分钟"), Double(point.seconds) / 60))
                    .foregroundStyle(AppTheme.trendBarStyle(selected: selectedKey == point.bucketKey))
                    .cornerRadius(3)
                    .accessibilityLabel(point.bucketKey)
                    .accessibilityValue(RecentListeningTrend.duration(point.seconds))
                    .accessibilityIdentifier("statsTrendBar-\(point.bucketKey)")
            }
            .chartXScale(domain: points.map(\.bucketKey))
            .chartYScale(domain: 0...max(1, Double(points.map(\.seconds).max() ?? 0) / 60))
            .chartXAxis {
                AxisMarks(values: points.map(\.bucketKey)) { value in
                    if let key = value.as(String.self) {
                        AxisValueLabel { Text(StatsAggregator.bucketLabel(key)).font(.caption2) }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let plot = geometry[anchor]
                        TrendColumnTouchView { x in
                            guard x >= 0, x <= plot.width,
                                  let key = proxy.value(atX: x, as: String.self),
                                  points.contains(where: { $0.bucketKey == key }) else { return }
                            selectedKey = key
                        }
                        .frame(width: plot.width, height: plot.height)
                        .position(x: plot.midX, y: plot.midY)
                    }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("最近 7 天收听趋势")
            .accessibilityValue(points.map { "\($0.bucketKey)：\(RecentListeningTrend.duration($0.seconds))" }.joined(separator: "；"))
            .accessibilityIdentifier("statsTrendChart")
        }
        .onChange(of: points) { _, points in
            if !points.contains(where: { $0.bucketKey == selectedKey }) { selectedKey = nil }
        }
    }
}

/// A horizontal pan chooses columns; a vertical pan fails immediately so the
/// enclosing ScrollView retains its normal scrolling. Zero-height bars keep a
/// full-column touch target without inventing a nonzero listening duration.
private struct TrendColumnTouchView: UIViewRepresentable {
    let selectX: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selectX: selectX) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        tap.cancelsTouchesInView = false
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.selectX = selectX }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var selectX: (CGFloat) -> Void
        init(selectX: @escaping (CGFloat) -> Void) { self.selectX = selectX }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            selectX(gesture.location(in: gesture.view).x)
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed || gesture.state == .ended else { return }
            selectX(gesture.location(in: gesture.view).x)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
