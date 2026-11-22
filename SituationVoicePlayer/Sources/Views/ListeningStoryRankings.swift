import SwiftUI

enum StoryRankingRange: String, CaseIterable {
    case week = "七天", month = "一个月", year = "一年", all = "全部"
}

struct StoryRankingSelection {
    var type: ListeningRanking
    var range: StoryRankingRange
    var month: String
    var year: String
    var topRow: Int?

    init(type: ListeningRanking, report: ReviewSnapshot) {
        self.type = type
        range = report.kind == .monthly ? .month : .year
        year = String(report.key.prefix(4))
        let today = PlaybackStatSplitter.dateKey(from: Date(), calendar: PlaybackStatSplitter.listeningCalendar)
        month = report.kind == .monthly ? report.key : min(String(today.prefix(7)), year + "-12")
    }

    var period: StatPeriod? {
        let calendar = PlaybackStatSplitter.listeningCalendar
        switch range {
        case .week: return .lastDays(7)
        case .month: return ListeningReviewKind.monthly.period(month, calendar: calendar)
        case .year: return ListeningReviewKind.annual.period(year, calendar: calendar)
        case .all: return .all
        }
    }
}

/// A destination in the report itself. The owning report retains its page and this filter.
struct ListeningStoryRankings: View {
    let report: ReviewSnapshot
    @Binding var selection: StoryRankingSelection
    let onBack: () -> Void
    @EnvironmentObject private var store: LibraryStore
    @State private var ranks: [RankEntry] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) { Label("返回报告", systemImage: "chevron.backward") }
                .accessibilityIdentifier("reportRankingBack")
            Text("收听排行").font(.largeTitle.bold()).foregroundStyle(AppTheme.titleInk)
            Picker("排行类别", selection: $selection.type) {
                ForEach(report.rankingKinds, id: \.self) { Text(L10n.key($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reportRankingKind")
            Picker("时间范围", selection: $selection.range) {
                ForEach(StoryRankingRange.allCases, id: \.self) { Text(L10n.key($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reportRankingRange")
            if selection.range == .month || selection.range == .year {
                let monthly = selection.range == .month
                let kind: ListeningReviewKind = monthly ? .monthly : .annual
                Picker("统计期间", selection: monthly ? $selection.month : $selection.year) {
                    ForEach(periodKeys(for: kind), id: \.self) { key in
                        Text(kind.label(key)).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("reportRankingPeriod")
            }
            Text("\(report.scope.displayName) · \(ranks.count) 项")
                .font(.caption).foregroundStyle(AppTheme.secondaryText)
            if let errorMessage {
                ContentUnavailableView {
                    Label("排行读取失败", systemImage: "exclamationmark.circle")
                } description: { Text(errorMessage) } actions: { Button("重试", action: refresh) }
            } else if ranks.isEmpty {
                ContentUnavailableView("这个期间没有收听记录", systemImage: "headphones")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(ranks.indices, id: \.self) { index in
                            ListeningRankRow(position: index + 1, entry: ranks[index],
                                             badge: ListeningRankBadge(entry: ranks[index], store: store, size: 32))
                                .id(index)
                        }
                    }.scrollTargetLayout()
                }
                .scrollPosition(id: $selection.topRow, anchor: .top)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .frame(maxWidth: 740)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .appPageBackground()
        .tint(AppTheme.accent)
        .onAppear(perform: refresh)
        .onChange(of: selection.type) { resetList() }
        .onChange(of: selection.period) { resetList() }
        .onChange(of: store.statsRevision) { refresh() }
        .onChange(of: store.contentRevision) { refresh() }
        .accessibilityAction(.escape) { onBack() }
    }

    private func periodKeys(for kind: ListeningReviewKind) -> [String] {
        kind.selectablePeriods(including: [kind == .monthly ? selection.month : selection.year])
    }

    private func resetList() {
        selection.topRow = nil
        refresh()
    }

    private func refresh() {
        guard let period = selection.period else { return }
        do {
            let rows = try store.listeningRows(period: period)
            ranks = ListeningRanking.allRanks(rows, scope: report.scope)[selection.type] ?? []
            errorMessage = nil
        } catch {
            ranks = []
            errorMessage = error.localizedDescription
        }
    }
}
