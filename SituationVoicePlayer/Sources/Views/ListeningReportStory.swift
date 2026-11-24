import SwiftUI

/// Native reproduction of the 428 × 926 report artwork. Each period uses the
/// same scoped snapshot that supplies the detailed report and its rankings.
struct ListeningReportStory: View {
    let report: ReviewSnapshot
    @Binding var page: Int
    let animatesArtwork: Bool
    let playsSequence: Bool
    let onClose: () -> Void
    let onDone: () -> Void
    let onShowRanking: (ListeningRanking) -> Void
    var onShare: ((ListeningRanking) -> Void)? = nil
    // A share image lays out the completed content as one continuous report,
    // without the interactive pager's repeated header, controls or record footer.
    var exportsLongImage = false
    var exportSoundRanking: ListeningRanking = .voices
    var exportImages: [String: UIImage] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var swiping = false
    @State private var shownGroups = 0
    @State private var visit = 0
    @State private var departure: DepartingPage?
    @State private var fadeEnds: ContinuousClock.Instant?
    @State private var soundRanking: ListeningRanking = .voices
    @State private var started: Date?
    @State private var wireFinished = false

    private func rankingKind(on index: Int) -> ListeningRanking {
        if index == 2 { return .works }
        return report.scope == .personal ? .creators : (!exportsLongImage ? soundRanking : exportSoundRanking)
    }

    private struct SequenceCue: Equatable {
        let visit: Int
        let page: Int
        let groupCount: Int
        let rank: ListeningRanking?
        let active: Bool
        let reducedMotion: Bool
        let voiceOver: Bool
    }

    private struct DepartingPage {
        let index: Int
        let shownGroups: Int
    }

    private var pageTurnSeconds: Double { reduceMotion ? 0.14 : 0.34 }
    private static let fadeSeconds = 0.70

    private func groupCount(on index: Int) -> Int {
        if index == 0 { return 2 }
        if index == 1 { return 5 }
        let rank = rankingKind(on: index)
        let rows = min(report.ranks[rank]?.count ?? 0, report.kind.previewLimit(for: rank))
        // Heading, optional category picker, ranked rows (or one empty state), then the full ranking link.
        return (index == 3 ? 3 : 2) + max(1, rows)
    }

    private var sequence: SequenceCue {
        SequenceCue(visit: visit, page: page, groupCount: groupCount(on: page),
                    rank: page >= 2 ? rankingKind(on: page) : nil,
                    active: playsSequence && scenePhase == .active && !swiping && departure == nil,
                    reducedMotion: reduceMotion, voiceOver: voiceOver)
    }

    @MainActor private func playSequence(_ cue: SequenceCue) async {
        guard !Task.isCancelled, cue.active, cue == sequence else { return }
        if cue.voiceOver {
            shownGroups = cue.groupCount
            return
        }
        do {
            let clock = ContinuousClock()
            while shownGroups < cue.groupCount {
                // Let the landed page draw at zero opacity before starting its title.
                // A paused story resumes after its last revealed group.
                try await Task.sleep(for: shownGroups == 0 ? .milliseconds(400) : .seconds(1))
                guard !Task.isCancelled, cue == sequence else { return }
                fadeEnds = clock.now.advanced(by: .seconds(cue.reducedMotion ? 0 : Self.fadeSeconds))
                withAnimation(cue.reducedMotion ? nil : .easeInOut(duration: Self.fadeSeconds)) {
                    shownGroups += 1
                }
            }
            guard cue.page < 3 else { return }
            // The first page also contains the original four-second earphone drawing.
            let remainingWire = cue.page == 0 && !cue.reducedMotion && !wireFinished
                ? max(0, ReportWire.duration + (started?.timeIntervalSinceNow ?? 0)) : 0
            let remainingFade = fadeEnds.map { clock.now.duration(to: $0) } ?? .zero
            try await Task.sleep(for: max(.seconds(remainingWire), remainingFade) + .seconds(2))
            guard !Task.isCancelled, cue == sequence else { return }
            changePage(cue.page + 1)
        } catch is CancellationError {
            // A page change, interaction, covered story, or scene change owns the next schedule.
        } catch { return }
    }

    private func visible(_ group: Int, on index: Int) -> Bool {
        if exportsLongImage { return true }
        if index == page { return group <= shownGroups }
        if let departure, departure.index == index { return group <= departure.shownGroups }
        return false
    }

    var body: some View {
        if exportsLongImage {
            exportLongBoard
        } else {
            animatedBody
        }
    }

    private var animatedBody: some View {
        let cue = sequence
        return GeometryReader { geometry in
            // In wide windows the board scrolls vertically to keep type legible.
            let wide = geometry.size.width > geometry.size.height
            let scale = wide ? min(1.2, geometry.size.width / 428) : min(geometry.size.width / 428, geometry.size.height / 926)
            if wide {
                ScrollView {
                    scaledBoard(scale)
                        .frame(maxWidth: .infinity)
                        .padding(.top, geometry.safeAreaInsets.top)
                }
            } else {
                scaledBoard(scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .background(ReportPaint.paper)
        .ignoresSafeArea()
        .foregroundStyle(ReportPaint.ink)
        .onChange(of: animatesArtwork, initial: true) { _, running in
            if running && started == nil { started = Date() }
        }
        .onChange(of: page) { _, newPage in if newPage != 0 { wireFinished = true } }
        .onChange(of: reduceMotion, initial: true) { _, reduced in if reduced { wireFinished = true } }
        .task(id: cue) { await playSequence(cue) }
        .task(id: visit) {
            guard departure != nil else { return }
            let currentVisit = visit
            // Native finger paging commits at landing. Programmatic turns also
            // need the departing text while its board is sliding out of view.
            try? await Task.sleep(for: .seconds(pageTurnSeconds))
            guard !Task.isCancelled, visit == currentVisit else { return }
            departure = nil
        }
        .accessibilityAction(.escape, onClose)
    }

    private func scaledBoard(_ scale: CGFloat) -> some View {
        board
            .frame(width: 428, height: 926, alignment: .topLeading)
            .clipped()
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: 428 * scale, height: 926 * scale, alignment: .topLeading)
    }

    private var exportLongBoard: some View {
        VStack(spacing: 0) {
            header.frame(width: 428, height: 154, alignment: .topLeading)
            ZStack(alignment: .topLeading) {
                Image("LaunchArtwork").resizable()
                    .frame(width: 1086 * 0.449, height: 1448 * 0.449)
                    .offset(x: -5.288, y: -60).opacity(0.4)
                    .frame(width: 428, height: 300, alignment: .topLeading)
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.60),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                duration.offset(y: -100)
            }
            .frame(width: 428, height: 300, alignment: .topLeading)
            .clipped()
            footprint.frame(width: 428, height: 410, alignment: .topLeading)
            ForEach(2..<4) { index in
                ranking(on: index)
                    .frame(width: 428, height: exportRankingHeight(on: index), alignment: .topLeading)
                    .padding(.top, 24)
            }
            ZStack(alignment: .topLeading) {
                ReportVinyl().position(x: 214, y: 250)
                ReportTonearm().offset(x: 304, y: 53)
            }
            .frame(width: 428, height: 250, alignment: .topLeading)
            .clipped()
            .accessibilityHidden(true)
        }
        .frame(width: 428)
        .fixedSize(horizontal: false, vertical: true)
        .background(ReportPaint.paper)
        .foregroundStyle(ReportPaint.ink)
        .transaction { $0.disablesAnimations = true }
    }

    private func exportRankingHeight(on index: Int) -> CGFloat {
        let type = rankingKind(on: index)
        let count = min(report.ranks[type]?.count ?? 0, report.kind.previewLimit(for: type))
        guard count > 0 else { return 180 }
        return (type == .works ? 74 : 111) + CGFloat(count) * rankingRowHeight(for: type) + 16
    }

    private func rankingRowHeight(for type: ListeningRanking) -> CGFloat {
        if report.kind == .annual && type == .works { return 37 }
        return type != .works && report.kind == .monthly ? 94 : 67
    }

    private var board: some View {
        ZStack(alignment: .topLeading) {
            ReportPaint.paper
            pager.simultaneousGesture(DragGesture(minimumDistance: 10)
                .updating($swiping) { _, dragging, _ in dragging = true })
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animatesArtwork || reduceMotion)) { frame in
                let elapsed = started.map { max(0, frame.date.timeIntervalSince($0)) } ?? 0
                ReportVinyl().equatable()
                    .rotationEffect(.degrees(reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 22) / 22 * 360))
                    .position(x: 214, y: 926)
            }
            .accessibilityHidden(true).allowsHitTesting(false)
            ReportTonearm()
                .offset(x: 304, y: 729)
                .accessibilityHidden(true).allowsHitTesting(false)
            header
                .zIndex(1)
            pagination
                .padding(.leading, 12)
                .padding(.top, 649)
                .zIndex(1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var pager: some View {
        if reduceMotion {
            pageContents(page)
                .id(page)
                .transition(.opacity)
                .simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { value in
                    let dx = value.translation.width
                    guard abs(dx) > abs(value.translation.height) * 1.35 else { return }
                    changePage(page + (dx < 0 ? 1 : -1))
                })
        } else {
            TabView(selection: Binding(get: { page }, set: { selectPage($0, sliding: false) })) {
                ForEach(0..<4) { index in
                    pageContents(index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: 428, height: 926)
        }
    }

    private func pageContents(_ index: Int) -> some View {
        ZStack(alignment: .topLeading) {
            if index == 0 {
                Group {
                    if exportsLongImage {
                        Image("LaunchArtwork").resizable()
                            .frame(width: 1086 * 0.449, height: 1448 * 0.449).opacity(0.4)
                    } else {
                        ReportWire(started: started, running: animatesArtwork,
                                   finished: wireFinished || reduceMotion)
                    }
                }
                    .offset(x: -5.288, y: 131.494)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
            ZStack(alignment: .topLeading) {
                switch index {
                case 0: duration
                case 1: footprint
                default: ranking(on: index)
                }
            }
            .frame(width: 428, height: 450, alignment: .topLeading)
            .offset(y: 164)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("storyPage\(index + 1)")
            if index >= 2 && !exportsLongImage {
                Button { onShowRanking(rankingKind(on: index)) } label: {
                    HStack(spacing: 5) {
                        Text("查看完整排行")
                        Image(systemName: "arrow.up.right").font(.system(size: 13))
                    }.font(.system(size: 14, weight: .medium))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("storyFullRanking")
                .reportGroup(visible(groupCount(on: index), on: index))
                .frame(width: 372, alignment: .trailing)
                .padding(.leading, 28).padding(.top, 608)
            }
        }
        .frame(width: 428, height: 926, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityHidden(index != page)
        .allowsHitTesting(index == page)
    }

    private func changePage(_ index: Int) {
        guard (0..<4).contains(index), index != page else { return }
        withAnimation(reduceMotion ? .easeOut(duration: pageTurnSeconds) : .smooth(duration: pageTurnSeconds)) {
            selectPage(index, sliding: true)
        }
    }

    private func selectPage(_ index: Int, sliding: Bool) {
        guard (0..<4).contains(index), index != page else { return }
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            departure = sliding ? DepartingPage(index: page, shownGroups: shownGroups) : nil
            shownGroups = 0
            fadeEnds = nil
            visit += 1
        }
        page = index
    }

    private var header: some View {
        ZStack(alignment: .topLeading) {
            if !exportsLongImage {
            HStack(spacing: 6) {
                ForEach(0..<4) { index in
                    Button { changePage(index) } label: {
                        Capsule().fill(index == page ? ReportPaint.accent : ReportPaint.rule)
                            .frame(width: 90, height: 2).frame(height: 26)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("第\(index + 1)页")
                    .accessibilityAddTraits(index == page ? .isSelected : [])
                }
            }.offset(x: 24, y: 40)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                    .frame(width: 48, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("关闭报告").accessibilityIdentifier("storyClose")
            .offset(x: 10, y: 62)
            }
            Text(report.kind.title + " · " + periodLabel)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 310, height: 30, alignment: .trailing).offset(x: 92, y: 69)
            Text(report.scope == .combined ? L10n.text("合并统计") : report.scope.displayName)
                .font(.system(size: 12)).foregroundStyle(ReportPaint.subtle)
                .offset(x: 27, y: 122)
            if page == 3, !exportsLongImage, let onShare {
                Button { onShare(rankingKind(on: 3)) } label: {
                    Label("生成长图分享", systemImage: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 172, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("storyShareLongImage")
                .offset(x: 230, y: 106)
            }
        }
    }

    private var periodLabel: String {
        if report.kind == .annual { return String(report.key.prefix(4)) }
        return report.kind.label(report.key)
    }

    private var duration: some View {
        ZStack(alignment: .topLeading) {
            Text("总收听时长").font(.system(size: 24, weight: .medium))
                .frame(width: 428, height: 40).offset(y: 116)
                .accessibilityIdentifier("storyDurationTitle")
                .reportGroup(visible(1, on: 0))
            Text(listeningClock(report.summary.totalSeconds))
                .font(.custom("Baskerville", fixedSize: 100)).lineLimit(1).minimumScaleFactor(0.53)
                .frame(width: 380, height: 120).offset(x: 24, y: 181)
                .accessibilityIdentifier("storyDurationValue")
                .accessibilityLabel(listeningDuration(report.summary.totalSeconds))
                .reportGroup(visible(2, on: 0))
            Text(listeningClockUnit(report.summary.totalSeconds)).font(.system(size: 18, weight: .medium)).foregroundStyle(ReportPaint.accent)
                .frame(width: 428, height: 32).offset(y: 292)
                .accessibilityIdentifier("storyDurationUnit")
                .reportGroup(visible(2, on: 0))
                .accessibilityHidden(true)
        }
    }

    private var footprint: some View {
        ZStack(alignment: .topLeading) {
            Text("收听足迹").font(.system(size: 36, weight: .semibold)).offset(x: 27, y: 20)
                .accessibilityIdentifier("storyFootprintTitle")
                .reportGroup(visible(1, on: 1))
            metric(L10n.text("收听作品"), "\(report.summary.distinctWorks)", L10n.text("部")).offset(x: 28, y: 127)
                .accessibilityIdentifier("storyFootprintMetric1")
                .reportGroup(visible(2, on: 1))
            metric(L10n.text("收听天数"), "\(report.summary.activeDays)", L10n.text("天")).offset(x: 222, y: 127)
                .accessibilityIdentifier("storyFootprintMetric2")
                .reportGroup(visible(3, on: 1))
            metric(L10n.text("最长连续收听"), "\(report.summary.longestStreakDays)", L10n.text("天")).offset(x: 28, y: 278)
                .accessibilityIdentifier("storyFootprintMetric3")
                .reportGroup(visible(4, on: 1))
            metric(L10n.text("最常收听时段"), report.peakHour.map { String(format: "%02d–%02d", $0, ($0 + 1) % 24) } ?? "—", L10n.text("时"), size: 38)
                .offset(x: 222, y: 278)
                .accessibilityIdentifier("storyFootprintMetric4")
                .reportGroup(visible(5, on: 1))
        }
    }

    private func metric(_ title: String, _ value: String, _ unit: String, size: CGFloat = 46) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(ReportPaint.rule).frame(width: 177, height: 1)
            Text(title).font(.system(size: 15)).foregroundStyle(ReportPaint.subtle).offset(y: 16)
            Text(value).font(.custom("Baskerville", fixedSize: size)).lineLimit(1).minimumScaleFactor(0.65)
                .frame(width: 148, height: 60, alignment: .leading).offset(x: 8, y: 49)
            Text(unit).font(.system(size: 14)).foregroundStyle(ReportPaint.accent)
                .frame(width: 173, alignment: .trailing).offset(y: 81)
        }
        .frame(width: 177, height: 112, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func ranking(on index: Int) -> some View {
        let type = rankingKind(on: index)
        let entries = Array((report.ranks[type] ?? []).prefix(report.kind.previewLimit(for: type)))
        let isWorks = type == .works
        let compact = report.kind == .annual && isWorks
        let rowHeight = rankingRowHeight(for: type)
        return ZStack(alignment: .topLeading) {
            Text(isWorks ? L10n.text("常听作品排行") : L10n.text("常听声音排行"))
                .font(.system(size: 34, weight: .semibold)).offset(x: 27, y: 8)
                .reportGroup(visible(1, on: index))
            if !isWorks { soundPicker.offset(x: 28, y: 55).reportGroup(visible(2, on: index)) }
            if entries.isEmpty {
                Text("所选期间暂无\(L10n.key(type.rawValue))收听记录")
                    .font(.system(size: 15)).foregroundStyle(ReportPaint.subtle)
                    .offset(x: 28, y: isWorks ? 104 : 140)
                    .reportGroup(visible(isWorks ? 2 : 3, on: index))
            } else {
                VStack(spacing: 0) {
                    ForEach(entries.indices, id: \.self) { i in
                        ReportRankingRow(index: i, entry: entries[i], kind: type, compact: compact,
                                         exportImage: exportImages[type.rawValue + "|" + entries[i].id], isExport: exportsLongImage)
                            .frame(height: rowHeight)
                            .overlay(alignment: .top) { Rectangle().fill(ReportPaint.rule).frame(height: 0.8) }
                            .reportGroup(visible(i + (isWorks ? 2 : 3), on: index))
                    }
                }.frame(width: 372).offset(x: 28, y: isWorks ? 74 : 111)
            }
        }
    }

    private var soundPicker: some View {
        HStack(spacing: 15) {
            if report.scope == .personal {
                Text("创作者").foregroundStyle(ReportPaint.accent)
            } else {
                ForEach([ListeningRanking.voices, .circles], id: \.self) { type in
                    if type == .circles { Rectangle().fill(ReportPaint.rule).frame(width: 1, height: 16) }
                    if exportsLongImage {
                        Text(L10n.key(type.rawValue))
                            .foregroundStyle(exportSoundRanking == type ? ReportPaint.accent : ReportPaint.subtle)
                            .frame(minWidth: 39, minHeight: 44, alignment: .leading)
                    } else { Button {
                        if soundRanking != type {
                            shownGroups = 2
                            soundRanking = type
                        }
                    } label: {
                        Text(L10n.key(type.rawValue)).foregroundStyle(soundRanking == type ? ReportPaint.accent : ReportPaint.subtle)
                            .frame(minWidth: 39, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("storyKind-" + type.rawValue)
                    .accessibilityAddTraits(soundRanking == type ? .isSelected : [])
                    }
                }
            }
        }.font(.system(size: 15, weight: .medium)).frame(height: 44)
    }

    private var pagination: some View {
        ZStack {
            Text(String(format: "%02d   /   04", page + 1)).tracking(2)
                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(ReportPaint.subtle)
                .accessibilityLabel("第\(page + 1)页，共4页").accessibilityIdentifier("storyPageNumber")
            HStack {
                if page > 0 {
                    Button { changePage(page - 1) } label: {
                        Image(systemName: "arrow.left").font(.system(size: 21, weight: .light)).frame(width: 52, height: 50)
                            .contentShape(Rectangle())
                    }.accessibilityLabel("上一页").accessibilityIdentifier("storyPrevious")
                }
                Spacer()
                if page < 3 {
                    Button { changePage(page + 1) } label: {
                        Image(systemName: "arrow.right").font(.system(size: 21, weight: .light)).frame(width: 52, height: 50)
                            .contentShape(Rectangle())
                    }.accessibilityLabel("下一页").accessibilityIdentifier("storyNext")
                } else {
                    Button(action: onDone) {
                        Text("完成").font(.system(size: 15, weight: .medium)).frame(width: 58, height: 50)
                            .contentShape(Rectangle())
                    }.accessibilityIdentifier("storyDone")
                }
            }
        }.frame(width: 404, height: 50)
    }
}

private enum ReportPaint {
    static let paper = Color(red: 250 / 255, green: 248 / 255, blue: 242 / 255)
    static let ink = Color(red: 41 / 255, green: 41 / 255, blue: 36 / 255)
    static let subtle = Color(red: 102 / 255, green: 100 / 255, blue: 86 / 255)
    static let accent = Color(red: 154 / 255, green: 50 / 255, blue: 42 / 255)
    static let rule = Color(red: 217 / 255, green: 213 / 255, blue: 200 / 255)
}

private extension View {
    func reportGroup(_ revealed: Bool) -> some View {
        opacity(revealed ? 1 : 0)
            .allowsHitTesting(revealed)
            .accessibilityHidden(!revealed)
    }
}

private struct ReportRankingRow: View {
    let index: Int
    let entry: RankEntry
    let kind: ListeningRanking
    let compact: Bool
    var exportImage: UIImage? = nil
    var isExport = false
    @EnvironmentObject private var store: LibraryStore
    @State private var thumbnailPath: String?

    var body: some View {
        let size: CGFloat = compact ? 25 : 39
        HStack(spacing: 0) {
            Text(String(format: "%02d", index + 1)).font(.custom("Georgia", fixedSize: 14))
                .foregroundStyle(index == 0 ? ReportPaint.accent : ReportPaint.subtle)
                .frame(width: 33, alignment: .leading)
            Group {
                if let exportImage {
                    Image(uiImage: exportImage).resizable().aspectRatio(contentMode: .fill)
                } else if let badge = ListeningRankBadge(entry: entry, store: store, size: size) {
                    badge
                } else if let thumbnailPath {
                    CoverImageView(path: thumbnailPath, cornerRadius: 4, maxPixels: 144)
                }
                else {
                    ZStack {
                        Color(red: 0.85, green: 0.75, blue: 0.70)
                        Image(systemName: kind == .works ? "music.note" : "person.fill")
                            .font(.system(size: size * 0.48)).foregroundStyle(ReportPaint.accent.opacity(0.72))
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: kind == .works ? 4 : size / 2))
            Text(entry.name).font(.system(size: compact ? 15 : 18, weight: .medium))
                .lineLimit(1).truncationMode(.tail).padding(.leading, 12)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(listeningClock(entry.seconds)).font(.system(size: 14)).monospacedDigit()
                Text(listeningClockUnit(entry.seconds)).font(.system(size: 11))
            }
            .foregroundStyle(ReportPaint.subtle).fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(listeningDuration(entry.seconds))
        }
        .accessibilityElement(children: .combine)
        .task(id: entry.id + kind.rawValue) {
            guard !isExport else { return }
            thumbnailPath = nil
            if kind == .works, let work = entry.workID { thumbnailPath = store.coverPath(forWorkID: work) }
        }
    }
}

/// The wire uses the approved source and mask. The placement and four-second
/// timeline belong to this board; the opening animation uses its own timing.
private struct ReportWire: View {
    static let duration = 4.0
    let started: Date?
    let running: Bool
    let finished: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running || finished)) { frame in
            let elapsed = started.map { max(0, frame.date.timeIntervalSince($0)) } ?? 0
            let progress = finished ? 1 : min(1, elapsed / Self.duration)
            Image("LaunchArtwork").resizable()
                .frame(width: 1086 * 0.449, height: 1448 * 0.449)
                .mask {
                    if progress < 1, let spec = LaunchArtworkSpecification.approved {
                        LaunchArtworkMask(spec: spec, drawing: spec.drawing(at: progress))
                    } else { Color.white }
                }
                .opacity(0.4)
        }
    }
}

private struct ReportTonearm: View {
    var body: some View {
        Canvas { context, _ in
            let red = ReportPaint.accent
            let pivot = CGRect(x: 75, y: 6, width: 18, height: 18)
            let mount = Path(ellipseIn: pivot)
            context.fill(mount, with: .color(ReportPaint.ink))
            context.stroke(Path(ellipseIn: pivot.insetBy(dx: 2.5, dy: 2.5)),
                           with: .color(ReportPaint.paper.opacity(0.65)), lineWidth: 1)

            // The arm is fixed to the board. Only the record underneath rotates.
            var arm = Path()
            arm.move(to: CGPoint(x: 84, y: 15))
            arm.addLine(to: CGPoint(x: 76, y: 39))
            arm.addQuadCurve(to: CGPoint(x: 69, y: 46), control: CGPoint(x: 74, y: 44))
            arm.addLine(to: CGPoint(x: 31, y: 58))
            context.stroke(arm, with: .color(red),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            var highlight = context
            highlight.translateBy(x: -0.5, y: -0.8)
            highlight.stroke(arm, with: .color(ReportPaint.paper.opacity(0.35)),
                             style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: pivot.insetBy(dx: 6, dy: 6)), with: .color(red))

            var head = context
            head.translateBy(x: 25, y: 60)
            head.rotate(by: .degrees(-19))
            var needle = Path()
            needle.move(to: CGPoint(x: -6, y: 2))
            needle.addLine(to: CGPoint(x: -9, y: 8))
            head.stroke(needle, with: .color(ReportPaint.paper), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            let cartridge = Path(roundedRect: CGRect(x: -9, y: -4, width: 19, height: 8), cornerRadius: 2)
            head.fill(cartridge, with: .color(red))
        }
        .frame(width: 98, height: 78)
        .shadow(color: .black.opacity(0.20), radius: 1.2, y: 1)
    }
}

private struct ReportVinyl: View, Equatable {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(stops: [
                .init(color: Color(white: 0.216), location: 0), .init(color: Color(white: 0.137), location: 0.42),
                .init(color: Color(white: 0.19), location: 0.78), .init(color: Color(white: 0.095), location: 1)
            ], center: .center, startRadius: 0, endRadius: 211))
            Circle().fill(LinearGradient(stops: [
                .init(color: .white.opacity(0.04), location: 0), .init(color: .white.opacity(0.13), location: 0.42),
                .init(color: .clear, location: 0.52), .init(color: .white.opacity(0.1), location: 0.75),
                .init(color: .clear, location: 1)
            ], startPoint: .topLeading, endPoint: UnitPoint(x: 1, y: 0.4)))
            Canvas { context, _ in
                for radius in stride(from: 75, through: 204, by: 3) {
                    let r = CGFloat(radius)
                    let circle = Path(ellipseIn: CGRect(x: 211 - r, y: 211 - r, width: 2 * r, height: 2 * r))
                    context.stroke(circle, with: .color(radius % 12 == 0 ? .gray.opacity(0.48) : .black.opacity(0.60)), lineWidth: 0.75)
                }
            }
            Circle().fill(Color(red: 201 / 255, green: 178 / 255, blue: 154 / 255)).frame(width: 138, height: 138)
            Circle().fill(Color(red: 232 / 255, green: 220 / 255, blue: 200 / 255)).frame(width: 128, height: 128)
            Rectangle().fill(Color(red: 181 / 255, green: 165 / 255, blue: 145 / 255)).frame(width: 118, height: 1).offset(y: -14)
            Text("厮磨").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(red: 88 / 255, green: 78 / 255, blue: 64 / 255)).offset(y: -32)
            Circle().fill(ReportPaint.paper).frame(width: 10, height: 10)
        }.frame(width: 422, height: 422).drawingGroup()
    }
}
