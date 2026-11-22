import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

enum ListeningReviewKind: String, Identifiable, CaseIterable, Sendable {
    case monthly, annual
    var id: Self { self }
    var entryTitle: String { self == .monthly ? L10n.text("月度回顾") : L10n.text("年度报告") }
    var title: String { self == .monthly ? L10n.text("月度回顾") : L10n.text("年度报告") }

    func previewLimit(for ranking: ListeningRanking) -> Int {
        if self == .annual { return ranking == .works ? 10 : 5 }
        return ranking == .works ? 5 : 3
    }

    func bucket(_ dateKey: String) -> String {
        String(dateKey.prefix(self == .monthly ? 7 : 4))
    }

    func label(_ key: String) -> String {
        guard let year = Int(key.prefix(4)),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(
                year: year, month: self == .monthly ? Int(key.suffix(2)) ?? 1 : 1, day: 1)) else { return key }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = AppLanguageSelection.shared.locale
        formatter.setLocalizedDateFormatFromTemplate(self == .monthly ? "yMMMM" : "y")
        return formatter.string(from: date)
    }

    func selectablePeriods(including saved: [String], now: Date = Date()) -> [String] {
        let today = PlaybackStatSplitter.dateKey(from: now, calendar: PlaybackStatSplitter.listeningCalendar)
        let current = bucket(today)
        let year = Int(today.prefix(4)) ?? 2026
        var keys = Set(saved.filter { !$0.isEmpty && $0 <= current })
        for y in min(2026, year)...year {
            if self == .annual {
                keys.insert(String(y))
            } else {
                for m in 1...12 {
                    let month = String(format: "%04d-%02d", y, m)
                    if month <= current { keys.insert(month) }
                }
            }
        }
        return keys.sorted(by: >)
    }

    func period(_ key: String, calendar: Calendar) -> StatPeriod? {
        let firstDay = key + (self == .monthly ? "-01" : "-01-01")
        guard let date = StatsAggregator.parseDateKey(firstDay, calendar: calendar),
              let interval = calendar.dateInterval(of: self == .monthly ? .month : .year, for: date)
        else { return nil }
        return .custom(from: interval.start, to: interval.end.addingTimeInterval(-1))
    }
}

private enum ListeningReviewPage: Hashable {
    case overview
    case ranking(ListeningRanking)
}

struct ReviewSnapshot: Sendable {
    let kind: ListeningReviewKind
    let key: String
    let scope: StatisticsScope
    let summary: StatsSummary
    let ranks: [ListeningRanking: [RankEntry]]
    let peakHour: Int?
    var title: String { kind.label(key) + " · " + kind.title }

    /// 只使用传入（已按库范围过滤）的行，绝不回退到未过滤总数。
    init(kind: ListeningReviewKind, key: String, rows: [PlayStatRow], scope: StatisticsScope) {
        self.kind = kind
        self.key = key
        self.scope = scope
        let scoped = scope.filter(rows)
        summary = StatsAggregator.summary(scoped, calendar: PlaybackStatSplitter.listeningCalendar)
        ranks = ListeningRanking.allRanks(scoped, scope: scope)
        let hours = StatsAggregator.hourHistogram(scoped)
        peakHour = hours.max().flatMap { $0 > 0 ? hours.firstIndex(of: $0) : nil }
    }

    var rankingKinds: [ListeningRanking] { ListeningRanking.kinds(for: scope) }
}

struct ListeningReviewView: View {
    let kind: ListeningReviewKind
    let scope: StatisticsScope
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preferences = StatisticsPreferences.shared
    @State private var key: String
    @State private var periodKeys: [String]
    @State private var snapshot: ReviewSnapshot?
    @State private var readError: String?
    @State private var page = ListeningReviewPage.overview
    @State private var showStory = true
    @State private var browserVisible = false
    @State private var storyPage = 0
    @State private var storyEntered = false
    @State private var artworkIsRunning = false
    @State private var storyClosing = false
    private enum RankingPresentation { case closed, preparing, visible, closing }
    @State private var rankingPresentation = RankingPresentation.closed
    @State private var rankingStates: [Int: StoryRankingSelection] = [:]
    @StateObject private var imageExport = ListeningReportImageExport()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(kind: ListeningReviewKind, scope: StatisticsScope = .combined) {
        self.kind = kind
        self.scope = scope
        let today = PlaybackStatSplitter.dateKey(from: Date(), calendar: PlaybackStatSplitter.listeningCalendar)
        let initial = kind.bucket(today)
        _key = State(initialValue: initial)
        _periodKeys = State(initialValue: [initial])
    }

    var body: some View {
        ZStack {
            if browserVisible || readError != nil {
                browser
                    .allowsHitTesting(!showStory || readError != nil)
                    .accessibilityHidden(showStory && readError == nil)
            }
            if showStory, readError == nil, let snapshot {
                ListeningReportStory(report: snapshot, page: $storyPage,
                                     animatesArtwork: artworkIsRunning && !imageExport.isBusy && imageExport.file == nil,
                                     playsSequence: artworkIsRunning && !storyClosing && rankingPresentation == .closed
                                         && !imageExport.isBusy && imageExport.file == nil,
                                     onClose: { finishStory(close: true) },
                                     onDone: { finishStory(close: false) },
                                     onShowRanking: { type in openRanking(type, report: snapshot) },
                                     onShare: { type in imageExport.start(report: snapshot, soundRanking: type, store: store) })
                    .opacity(storyEntered ? (rankingPresentation == .visible ? 0.82 : 1) : 0)
                    .offset(x: rankingPresentation == .visible && !reduceMotion ? -8 : 0,
                            y: reduceMotion || storyEntered ? 0 : (storyClosing ? 8 : 14))
                    .allowsHitTesting(!storyClosing && rankingPresentation == .closed)
                    .accessibilityHidden(rankingPresentation != .closed)
                    .task {
                        await Task.yield()
                        guard !Task.isCancelled, !storyClosing else { return }
                        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.24),
                                      completionCriteria: .logicallyComplete) {
                            storyEntered = true
                        } completion: {
                            if showStory && !storyClosing { artworkIsRunning = true }
                        }
                    }
                // Keep each opened list in place, so returning to it preserves the native
                // scroll view, its filters and its already-laid-out segmented controls.
                ForEach(rankingStates.keys.sorted(), id: \.self) { pageIndex in
                    if let saved = rankingStates[pageIndex] {
                        rankingPanel(for: pageIndex, selection: saved, report: snapshot)
                    }
                }
            }
            if let progress = imageExport.progress {
                Color.black.opacity(0.24).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView(value: Double(progress), total: 4).frame(width: 190)
                    Text("正在生成长图（\(progress)/4）").font(.subheadline)
                        .accessibilityIdentifier("storyExportProgress")
                    Button("取消") { imageExport.cancel() }
                        .accessibilityIdentifier("storyExportCancel")
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .zIndex(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationBackground(.clear)
        .preferredColorScheme(showStory && rankingPresentation == .closed && readError == nil ? .light : nil)
        .onAppear { refresh(periodsToo: true) }
        .onChange(of: key) { refresh() }
        .onChange(of: preferences.isEnabled(.collection)) { refresh() }
        .onChange(of: preferences.isEnabled(.personal)) { refresh() }
        .onChange(of: store.statsRevision) { refresh() }
        .onChange(of: store.contentRevision) { refresh(periodsToo: true) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh(periodsToo: true) } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh(periodsToo: true) }
        .onDisappear { imageExport.cancel() }
        .sheet(item: $imageExport.file, onDismiss: { imageExport.sharingDismissed() }) { file in
            ListeningReportImageShareSheet(file: file, onFinish: { error in
                imageExport.sharingFinished(fileID: file.id, error: error)
            })
        }
        .alert(imageExport.sharingError == nil ? L10n.text("长图生成失败") : L10n.text("长图分享失败"),
               isPresented: Binding(get: { imageExport.error != nil || imageExport.sharingError != nil },
                                    set: { if !$0 { imageExport.error = nil; imageExport.sharingError = nil } })) {
            Button("确定") { imageExport.error = nil; imageExport.sharingError = nil }
        } message: { Text(imageExport.sharingError ?? imageExport.error ?? "") }
    }

    private func rankingPanel(for pageIndex: Int, selection: StoryRankingSelection,
                              report: ReviewSnapshot) -> some View {
        let visible = storyPage == pageIndex && rankingPresentation == .visible
        let binding = Binding(
            get: { rankingStates[pageIndex] ?? selection },
            set: { if visible { rankingStates[pageIndex] = $0 } }
        )
        return ListeningStoryRankings(report: report, selection: binding, onBack: closeRanking)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > 0 && proxy.size.height > 0
            } action: { laidOut in
                guard laidOut, pageIndex == storyPage, rankingPresentation == .preparing else { return }
                withAnimation(rankingAnimation) { rankingPresentation = .visible }
            }
            .compositingGroup()
            .opacity(visible ? 1 : 0)
            .offset(x: reduceMotion || visible ? 0 : 14)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
            .zIndex(1)
    }

    private func openRanking(_ type: ListeningRanking, report: ReviewSnapshot) {
        if rankingStates[storyPage] != nil {
            withAnimation(rankingAnimation) { rankingPresentation = .visible }
        } else {
            rankingPresentation = .preparing
            rankingStates[storyPage] = StoryRankingSelection(type: type, report: report)
        }
    }

    private var rankingAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.26)
    }

    private func closeRanking() {
        guard rankingPresentation == .visible else { return }
        withAnimation(rankingAnimation, completionCriteria: .removed) {
            rankingPresentation = .closing
        } completion: {
            if rankingPresentation == .closing { rankingPresentation = .closed }
        }
    }

    private func finishStory(close: Bool) {
        guard !storyClosing else { return }
        let returnToStatistics = close && !browserVisible
        if !returnToStatistics { browserVisible = true }
        artworkIsRunning = false
        storyClosing = true
        withAnimation(.easeIn(duration: reduceMotion ? 0.12 : 0.18)) {
            storyEntered = false
        } completion: {
            if returnToStatistics {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { dismiss() }
            } else {
                showStory = false
                storyClosing = false
            }
        }
    }

    private func generateReport() {
        guard !showStory, snapshot?.key == key else { return }
        storyPage = 0
        rankingStates = [:]
        rankingPresentation = .closed
        artworkIsRunning = false
        storyEntered = false
        storyClosing = false
        showStory = true
    }

    private var browser: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(kind == .annual ? L10n.text("年份") : L10n.text("月份"), selection: $key) {
                    ForEach(periodKeys, id: \.self) { Text(kind.label($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("reviewPeriod")
                .padding(.vertical, 6)
                Text(snapshot?.scope.scopeLabel ?? scope.scopeLabel)
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("reviewScope")
                if let readError {
                    ContentUnavailableView {
                        Label("报告读取失败", systemImage: "exclamationmark.circle")
                    } description: { Text(readError) } actions: {
                        Button("重试") { refresh(periodsToo: true) }
                    }
                } else if let snapshot {
                    Picker("报告内容", selection: $page) {
                        Text("概览").tag(ListeningReviewPage.overview)
                        ForEach(snapshot.rankingKinds, id: \.self) { type in
                            Text(L10n.key(type.rawValue)).tag(ListeningReviewPage.ranking(type))
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reviewPages")
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: 660)
                    TabView(selection: $page) {
                        Group {
                            if snapshot.summary.totalSeconds > 0 {
                                ScrollView {
                                    ReviewSummaryCard(report: snapshot)
                                        .padding(16).frame(maxWidth: 660)
                                }
                            } else {
                                ContentUnavailableView(kind == .annual ? L10n.text("这一年还没有收听记录") : L10n.text("这个月还没有收听记录"),
                                                       systemImage: "calendar")
                            }
                        }.tag(ListeningReviewPage.overview)
                        ForEach(snapshot.rankingKinds, id: \.self) { type in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("常听\(L10n.key(type.rawValue))").font(.headline).foregroundStyle(AppTheme.headingInk())
                                    ExpandableListeningRanking(kind: type, entries: snapshot.ranks[type] ?? [],
                                                               previewLimit: kind.previewLimit(for: type),
                                                               onDarkReviewCard: AppTheme.usesDarkPalette)
                                        .id(key)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(18)
                                .background(AppTheme.card,
                                            in: RoundedRectangle(cornerRadius: 18))
                                .padding(16).frame(maxWidth: 660)
                            }.tag(ListeningReviewPage.ranking(type))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    Button(kind == .monthly ? L10n.text("生成月度报告") : L10n.text("生成年度报告"), action: generateReport)
                        .buttonStyle(.bordered)
                        .tint(AppTheme.emphasisInk)
                        .accessibilityIdentifier("reviewGenerateReport")
                        .padding(.vertical, 8)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .appPageBackground()
            .appNavigationColors().navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("完成", systemImage: "chevron.backward") }
                        .accessibilityIdentifier("closeReview")
                }
                if let snapshot, snapshot.summary.totalSeconds > 0, readError == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: ReviewImage(report: snapshot,
                                                     showScope: true),
                                   preview: SharePreview(snapshot.title + " · " + snapshot.scope.displayName)) {
                            Label(L10n.text("分享") + kind.title, systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("shareListeningReport")
                    }
                }
            }

        }
    }

    private func refresh(periodsToo: Bool = false) {
        guard scenePhase == .active else { return }
        let calendar = PlaybackStatSplitter.listeningCalendar
        do {
            if periodsToo {
                let buckets = try store.listeningMonthKeys().map(kind.bucket)
                periodKeys = kind.selectablePeriods(including: buckets + [key])
            }
            guard let period = kind.period(key, calendar: calendar) else { return }
            guard preferences.isReviewEnabled(kind) else { return }
            snapshot = try ReviewSnapshot(kind: kind, key: key,
                                          rows: store.listeningRows(period: period), scope: scope)
            readError = nil
        } catch { readError = error.localizedDescription }
    }
}

private struct ReviewSummaryCard: View {
    let report: ReviewSnapshot

    private var background: LinearGradient {
        if AppTheme.usesCustomPalette { return AppTheme.statisticsSummaryGradient }
        return LinearGradient(colors: [Color(red: 0.22, green: 0.32, blue: 0.44),
                                       Color(red: 0.16, green: 0.15, blue: 0.29)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("厮磨").fontWeight(.semibold)
                Spacer()
                Text(report.title)
            }.font(.subheadline)
            Text(report.scope.displayName)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .overlay(Capsule().stroke(AppTheme.painted(.white.opacity(0.6), AppTheme.separator), lineWidth: 1))
                .accessibilityIdentifier("reviewScopeBadge")
            VStack(alignment: .leading, spacing: 4) {
                Text("总收听时长").font(.caption)
                    .foregroundStyle(AppTheme.painted(.white, AppTheme.emphasisInk))
                Text(listeningDuration(report.summary.totalSeconds))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
            }
            Divider().overlay(AppTheme.painted(.white.opacity(0.4), AppTheme.separator))
            fact(L10n.text("收听作品"), L10n.text("\(report.summary.distinctWorks) 部"))
            fact(L10n.text("收听天数"), L10n.text("\(report.summary.activeDays) 天"))
            fact(L10n.text("最长连续收听"), L10n.text("\(report.summary.longestStreakDays) 天"))
            if let peak = report.peakHour {
                fact(L10n.text("最常收听时段"), String(format: "%02d:00–%02d:00", peak, (peak + 1) % 24))
            }
            HStack(spacing: 12) {
                ForEach(report.rankingKinds.prefix(2), id: \.self) { type in
                    if let top = report.ranks[type]?.first {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("最常听") + L10n.key(type.rawValue)).font(.caption)
                            Text(top.name).font(.subheadline).lineLimit(1)
                        }
                    }
                }
            }
            if let favorite = report.ranks[.works]?.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text("听得最多的作品").font(.caption)
                    Text(favorite.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                    Text(listeningDuration(favorite.seconds)).font(.subheadline)
                }
            }
        }
        .foregroundStyle(AppTheme.painted(.white, AppTheme.ink))
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline)
            Spacer()
            Text(value).font(.headline)
        }
    }
}

/// Render only when the system requests the share item, keeping a stable snapshot while sharing.
private struct ReviewImage: Transferable {
    let report: ReviewSnapshot
    let showScope: Bool

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try await item.png()
        }
        .suggestedFileName { $0.report.title + ".png" }
    }

    @MainActor private func png() throws -> Data {
        let renderer = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 18) {
                ReviewSummaryCard(report: report)
                if showScope {
                    Text(report.scope.scopeLabel).font(.caption).foregroundStyle(AppTheme.secondaryText)
                }
                ForEach(report.rankingKinds, id: \.self) { type in
                    let entries = report.ranks[type] ?? []
                    if !entries.isEmpty {
                        Text("常听\(L10n.key(type.rawValue))").font(.headline).foregroundStyle(AppTheme.headingInk())
                        ForEach(0..<min(entries.count, report.kind.previewLimit(for: type)), id: \.self) { index in
                            ListeningRankRow(position: index + 1, entry: entries[index]).lineLimit(2)
                        }
                    }
                }
            }
            .frame(width: 360).padding(18).foregroundStyle(AppTheme.ink).background(AppTheme.painted(.white, AppTheme.background))
            .environment(\.colorScheme, .light).dynamicTypeSize(.large)
        )
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
