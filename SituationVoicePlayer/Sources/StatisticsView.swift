import SwiftUI
import Charts

struct StatisticsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = StatisticsPreferences.shared
    @StateObject private var arrangement = StatisticsArrangement()
    @State private var period = StatPeriod.lastDays(7)
    @State private var ranking = ListeningRanking.works
    @State private var scope: StatisticsScope = StatisticsPreferences.shared.defaultScope()
    @State private var report = ListeningReport()
    @State private var recentTrend = RecentListeningTrend(rows: [], now: Date())
    @State private var readError: String?
    @State private var editingDates = false
    @State private var reviewKind: ListeningReviewKind?
    @State private var visible = false
    @State private var moduleHeights: [StatisticsModule: CGFloat] = [:]
    @State private var observedScopes = StatisticsPreferences.shared.availableScopes

    private let periods: [StatPeriod] = [.today, .lastDays(7), .lastDays(30), .thisYear, .all]

    private var displayedModules: [StatisticsModule] {
        arrangement.isEditing ? arrangement.order : preferences.visibleModules
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !preferences.availableScopes.isEmpty && !preferences.reviewKinds.isEmpty {
                        HStack { Spacer(); reviewButtons }
                            .font(.subheadline.weight(.semibold))
                    }

                    if let readError {
                        ContentUnavailableView {
                            Label("统计读取失败", systemImage: "exclamationmark.circle")
                        } description: { Text(readError) } actions: {
                            Button("重试", action: refresh)
                        }
                    } else if preferences.availableScopes.isEmpty {
                        ContentUnavailableView("统计显示已关闭", systemImage: "chart.bar", description: Text("可在统计设置中开启；已有记录继续保留。"))
                    } else {
                        scopeBar
                        if arrangement.isEditing {
                            ZStack(alignment: .leading) {
                                Text("拖动组件调整顺序，松手保存；完成后返回统计。")
                                    .hidden().accessibilityHidden(true)
                                Text(arrangement.hint).lineLimit(1).minimumScaleFactor(0.85)
                            }
                            .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                            .accessibilityIdentifier("statsArrangementHint")
                        }
                        // Keep the pinned summary/period selector available even
                        // for an empty selected period. The trend has its own range.
                        ForEach(displayedModules) { module in
                            if arrangement.isEditing || report.summary.totalSeconds > 0 || module == .summary || module == .trend {
                                arrangedModule(module)
                            }
                        }
                        if report.summary.totalSeconds == 0 {
                            Label("所选周期还没有收听记录，可在总收听时长中切换周期。", systemImage: "headphones")
                                .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                                .accessibilityIdentifier("statsEmptyPeriod")
                        }
                        reorderHint
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: 740)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [StatisticsArrangement.type], delegate: StatisticsModuleDropDelegate(
                    arrangement: arrangement, preferences: preferences))
            }
            .modifier(ScrollContentEdges.topOnly)
            .accessibilityHidden(reviewKind != nil)
            .appPageBackground(AppTheme.porcelainBackground)
            .appNavigationColors().navigationTitle(L10n.text("统计"))
            .toolbar {
                if arrangement.isEditing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { arrangement.finish(preferences) }
                            .accessibilityIdentifier("statsArrangementDone")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        StatisticsSettingsView()
                    } label: {
                        Label("统计设置", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("statsSettings")
                }
            }
            .onAppear { visible = true; observedScopes = preferences.availableScopes; normalizeScope(); refresh() }
            .onDisappear { visible = false; arrangement.finish(preferences) }
            .onChange(of: period) { refresh() }
            .onChange(of: scope) { refresh() }
            .onChange(of: store.statsRevision) { refresh() }
            .onChange(of: store.contentRevision) { refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
                else { arrangement.cancelDrag(preferences) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: StatisticsPreferences.didChangeNotification)) { _ in
                let previousScope = scope
                normalizeScope()
                arrangement.synchronize(preferences)
                // Moving/hiding a card only changes presentation. Requery only
                // when the available library scope changed (scope itself has
                // its own onChange above), never during drag previews.
                if observedScopes != preferences.availableScopes {
                    observedScopes = preferences.availableScopes
                    if previousScope == scope { refresh() }
                }
            }
            .porcelainSheet(isPresented: $editingDates) {
                ListeningDatePicker(period: period) { period = $0 }
            }
            .fullScreenCover(item: $reviewKind) { ListeningReviewView(kind: $0, scope: scope) }
        }
    }

    // MARK: - 范围

    private var scopeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if preferences.bothEnabled {
                Picker("统计范围", selection: $scope) {
                    ForEach(preferences.availableScopes) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("statsScope")
            }
            Text(scope.scopeLabel).font(.caption).foregroundStyle(AppTheme.secondaryText)
                .accessibilityIdentifier("statsScopeLabel")
        }
    }

    // MARK: - 组件

    @ViewBuilder
    private func moduleView(_ module: StatisticsModule) -> some View {
        Group {
            switch module {
            case .summary: summary
            case .trend: trend
            case .hours: ListeningHoursView(hours: report.hours, periodName: period.displayName)
            case .rankings: rankings
            }
        }
    }

    private func arrangedModule(_ module: StatisticsModule) -> some View {
        VStack(spacing: 8) {
            if arrangement.isEditing {
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(AppTheme.secondaryText)
                    Text(module.displayName).font(.subheadline.weight(.semibold))
                    Spacer()
                    if !preferences.isPinned(module) {
                        Button(preferences.isEnabled(module) ? L10n.text("隐藏") : L10n.text("显示")) {
                            arrangement.setVisible(!preferences.isEnabled(module), module: module, preferences: preferences)
                        }
                        .accessibilityIdentifier("statsVisibility-\(module.rawValue)")
                        .anchorPreference(key: StatisticsArrangementActionBounds.self, value: .bounds) { [$0] }
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
            }
            if arrangement.isEditing && !preferences.isEnabled(module) {
                Label("\(module.displayName)已隐藏，可点「显示」恢复", systemImage: "eye.slash")
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 74)
                    .accessibilityIdentifier("statsHidden-\(module.rawValue)")
            } else {
                moduleView(module).allowsHitTesting(!arrangement.isEditing)
            }
        }
        .padding(arrangement.isEditing ? 4 : 0)
        .background {
            if arrangement.isEditing {
                RoundedRectangle(cornerRadius: 22).fill(AppTheme.groupedCard)
            }
        }
        .overlay {
            if arrangement.isEditing {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(AppTheme.accent.opacity(arrangement.dragged == module ? 0.8 : 0.25), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statsWidget-\(module.rawValue)")
        .accessibilityAction(named: L10n.text("整理统计组件")) { arrangement.enter(preferences) }
        .accessibilityAction(named: L10n.text("上移组件")) { arrangement.enter(preferences); arrangement.move(module, by: -1, preferences: preferences) }
        .accessibilityAction(named: L10n.text("下移组件")) { arrangement.enter(preferences); arrangement.move(module, by: 1, preferences: preferences) }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs((moduleHeights[module] ?? 0) - height) > 0.5 { moduleHeights[module] = height }
        }
        .modifier(StatisticsArrangementGesture(module: module, height: moduleHeights[module] ?? 1,
            arrangement: arrangement, preferences: preferences))
    }

    private var reorderHint: some View {
        Button { arrangement.enter(preferences) } label: {
            HStack {
                Label(arrangement.isEditing ? L10n.text("正在整理组件") : L10n.text("调整组件顺序与显示"), systemImage: "arrow.up.arrow.down")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(arrangement.isEditing)
        .accessibilityIdentifier("statsReorder")
    }

    private var reviewButtons: some View {
        HStack(spacing: 16) {
            ForEach(preferences.availableScopes.isEmpty ? [] : preferences.reviewKinds) { kind in
                Button(kind.entryTitle) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { reviewKind = kind }
                }
                    .accessibilityIdentifier(kind == .annual ? "statsAnnual" : "statsMonthly")
            }
        }
        .tint(AppTheme.emphasisInk)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var periodMenu: some View {
        Menu {
            ForEach(periods, id: \.displayName) { option in
                Button {
                    period = option
                } label: {
                    if period == option { Label(option.displayName, systemImage: "checkmark") }
                    else { Text(option.displayName) }
                }
            }
            Divider()
            Button("自定义") { editingDates = true }.accessibilityIdentifier("statsCustom")
        } label: {
            HStack(spacing: 6) {
                Text(period.displayName).foregroundStyle(AppTheme.emphasisInk)
                Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(AppTheme.iconTint)
            }
        }
        .accessibilityLabel("统计周期")
        .accessibilityValue(period.displayName)
        .accessibilityIdentifier("statsPeriod")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("总收听时长").font(.subheadline).foregroundStyle(AppTheme.textStyle(.secondary, AppTheme.emphasisInk))
                    Spacer()
                    periodMenu.font(.subheadline.weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("总收听时长").font(.subheadline).foregroundStyle(AppTheme.textStyle(.secondary, AppTheme.emphasisInk))
                    periodMenu.font(.subheadline.weight(.semibold))
                }
            }
            if case .custom(let from, let to) = period {
                Text(from.formatted(date: .abbreviated, time: .omitted) + " – " + to.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            Text(listeningDuration(report.summary.totalSeconds))
                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .accessibilityLabel("总收听时长")
                .accessibilityValue(listeningDuration(report.summary.totalSeconds))
                .accessibilityIdentifier("statsTotal")
            Divider()
            LazyVGrid(columns: [.init(.adaptive(minimum: 126), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 12) {
                metric(L10n.text("收听作品"), L10n.text("\(report.summary.distinctWorks) 部"))
                metric(L10n.text("收听天数"), L10n.text("\(report.summary.activeDays) 天"))
                metric(L10n.text("每个收听日平均"), listeningDuration(Int(report.summary.dailyAverageSeconds)))
                metric(L10n.text("最长连续收听"), L10n.text("\(report.summary.longestStreakDays) 天"))
            }

        }
        .foregroundStyle(AppTheme.usesDarkPalette ? AppTheme.ink : .primary)
        .padding(18)
        .background(AppTheme.statisticsSummaryGradient, in: RoundedRectangle(cornerRadius: 20))
    }

    private func metric(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(AppTheme.secondaryText)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    private var trend: some View {
        SevenDayListeningTrendView(points: recentTrend.points)
            .listeningCard()
    }

    private var rankings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("收听排行").font(.headline).foregroundStyle(AppTheme.headingInk())
                Spacer()
                Text(period.displayName).font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            Picker("排行类别", selection: $ranking) {
                ForEach(ListeningRanking.kinds(for: scope), id: \.self) { Text(L10n.key($0.rawValue)) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("statsRankKind")
            ExpandableListeningRanking(kind: ranking, entries: report.ranks[ranking] ?? [], previewLimit: 10)
                .id(ranking)

        }
        .listeningCard()
    }

    // MARK: - 数据

    private func normalizeScope() {
        let normalized = preferences.normalize(scope)
        if normalized != scope { scope = normalized }
        if !ListeningRanking.kinds(for: scope).contains(ranking) { ranking = .works }
    }

    /// 读取范围内全部行后按库范围过滤；只做显示过滤，不删除任何记录。
    private func refresh() {
        normalizeScope()
        guard visible, scenePhase == .active else { return }
        do {
            let now = Date()
            let rows = try store.listeningRows(period: period, now: now)
            let trendRows = period == .lastDays(7) ? rows : try store.listeningRows(period: .lastDays(7), now: now)
            report = ListeningReport(rows: preferences.availableScopes.isEmpty ? [] : scope.filter(rows), now: now, scope: scope)
            recentTrend = RecentListeningTrend(rows: preferences.availableScopes.isEmpty ? [] : scope.filter(trendRows), now: now)
            readError = nil
        } catch { readError = error.localizedDescription }
    }
}



private struct ListeningReport {
    var summary = StatsSummary()
    var hours = Array(repeating: 0, count: 24)
    var ranks: [ListeningRanking: [RankEntry]] = [:]
    var scope = StatisticsScope.combined

    init() {}

    init(rows: [PlayStatRow], now: Date, scope: StatisticsScope = .combined) {
        let calendar = PlaybackStatSplitter.listeningCalendar
        self.scope = scope
        // rows 已按范围过滤；合并时同一行只计入一次，总秒数不会重复。
        summary = StatsAggregator.summary(rows, calendar: calendar, now: now)
        hours = StatsAggregator.hourHistogram(rows)
        ranks = ListeningRanking.allRanks(rows, scope: scope)
    }
}

private struct ListeningHoursView: View {
    let hours: [Int]
    let periodName: String

    var body: some View {
        let peak = hours.max() ?? 0
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("24 小时收听时段").font(.headline).foregroundStyle(AppTheme.headingInk())
                Spacer()
                Text(periodName).font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 6) {
                ForEach(hours.indices, id: \.self) { hour in
                    let seconds = hours[hour]
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(seconds == 0 ? AppTheme.emptyListeningHour :
                                    AppTheme.peakListeningHour.opacity(0.22 + 0.78 * Double(seconds) / Double(max(1, peak))))
                            .frame(height: 21)
                        Text(String(format: "%02d", hour)).font(.caption2.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(hour) 点")
                    .accessibilityValue(listeningDuration(seconds))
                }
            }
            if peak > 0, let hour = hours.firstIndex(of: peak) {
                Text(String(format: L10n.text("最常收听　%02d:00–%02d:00"), hour, (hour + 1) % 24) + " · " + listeningDuration(peak))
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
            }
        }
        .listeningCard()
    }
}

private struct ListeningDatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var from: Date
    @State private var to: Date
    let apply: (StatPeriod) -> Void

    init(period: StatPeriod, apply: @escaping (StatPeriod) -> Void) {
        let now = Date()
        let calendar = PlaybackStatSplitter.listeningCalendar
        let range = period.dateKeyRange(now: now, calendar: calendar)
        _from = State(initialValue: range.flatMap { StatsAggregator.parseDateKey($0.from, calendar: calendar) }.map { min(now, $0) } ?? now)
        _to = State(initialValue: range.flatMap { StatsAggregator.parseDateKey($0.to, calendar: calendar) }.map { min(now, $0) } ?? now)
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            AppForm {
                DatePicker("从", selection: $from, in: ...Date(), displayedComponents: .date)
                DatePicker("至", selection: $to, in: ...Date(), displayedComponents: .date)
            }
            .onChange(of: from) { if from > to { to = from } }
            .onChange(of: to) { if to < from { from = to } }
            .appNavigationColors().navigationTitle(L10n.text("自定义统计周期")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("应用") { apply(.custom(from: from, to: to)); dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

func listeningDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = seconds % 3600 / 60
    if hours > 0 { return L10n.text("\(hours) 小时 \(minutes) 分") }
    if minutes > 0 { return L10n.text("\(minutes) 分 \(seconds % 60) 秒") }
    return L10n.text("\(seconds) 秒")
}

extension View {
    fileprivate func listeningCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AppTheme.groupedCard, in: RoundedRectangle(cornerRadius: 18))
    }
}
