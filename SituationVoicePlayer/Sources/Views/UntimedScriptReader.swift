import SwiftUI

/// 同一资料库中新阅读页先接住旧页尚未落盘的位置，不依赖 SwiftUI 视图销毁的先后。
@MainActor
final class ScriptReadingHandoff {
    fileprivate weak var current: ScriptReadingSession?
}

/// 一次阅读固定绑定来源与文字快照。旧页退出时不会读取已经切到下一轨的共享字幕。
@MainActor
final class ScriptReadingSession: ObservableObject {
    let sourceID: Int64
    let cues: [SubtitleCue]
    let repository: ReadingPositionRepository?
    var latest: ScriptReadingPosition?
    private var saved: ScriptReadingPosition?
    private var lastWrite = Date.distantPast
    @Published var errorMessage: String?

    init(sourceID: Int64, cues: [SubtitleCue], repository: ReadingPositionRepository?, handoff: ScriptReadingHandoff) {
        self.sourceID = sourceID
        self.cues = cues
        self.repository = repository
        handoff.current?.flush()
        do {
            latest = try repository?.scriptPosition(subtitleTrackID: sourceID)
            saved = latest
        } catch {
            errorMessage = L10n.text("暂时无法读取上次阅读位置。")
        }
        handoff.current = self
    }

    func record(index: Int, fraction: Double) {
        record(cues: cues, index: index, fraction: fraction)
    }

    /// 编辑器保存新版本后行 ID 保持稳定，阅读位置使用刚保存的文字快照。
    func record(cues: [SubtitleCue], index: Int, fraction: Double) {
        latest = ScriptReadingPosition(cues: cues, index: index, fraction: fraction)
        if Date().timeIntervalSince(lastWrite) >= 0.35 { flush() }
    }

    func flush() {
        guard let latest, latest != saved, let repository else { return }
        do {
            try repository.saveScriptPosition(latest, subtitleTrackID: sourceID)
            saved = latest
            lastWrite = Date()
            if errorMessage != nil { errorMessage = nil }
        } catch {
            errorMessage = L10n.text("阅读位置暂未保存，请稍后重试。")
        }
    }
}

/// 只供纯文字台本使用。带轴和混合台本继续走原来的播放跟随/摘选阅读器。
struct UntimedScriptReader<Row: View>: View {
    let cues: [SubtitleCue]
    let style: SubtitleStyle
    let horizontalInset: CGFloat
    let resetToken: UUID
    let isResizing: Bool
    let row: (SubtitleCue) -> Row
    @StateObject private var session: ScriptReadingSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var rowAnchor = SubtitleRowAnchor()
    @State private var frames: [Int: CGRect] = [:]
    @State private var ready = false
    @State private var restoredLayout: ReadingLayout?
    @State private var userInterrupted = false
    @State private var lastResetToken: UUID
    private let coordinateSpace = "untimedScriptViewport"

    init(cues: [SubtitleCue], sourceID: Int64, repository: ReadingPositionRepository?,
         handoff: ScriptReadingHandoff, style: SubtitleStyle, horizontalInset: CGFloat, resetToken: UUID, isResizing: Bool = false,
         @ViewBuilder row: @escaping (SubtitleCue) -> Row) {
        self.cues = cues
        self.style = style
        self.horizontalInset = horizontalInset
        self.resetToken = resetToken
        self.isResizing = isResizing
        _lastResetToken = State(initialValue: resetToken)
        self.row = row
        _session = StateObject(wrappedValue: ScriptReadingSession(sourceID: sourceID, cues: cues, repository: repository, handoff: handoff))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let message = session.errorMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("readingPositionError")
            }
            GeometryReader { viewport in
                let layout = ReadingLayout(size: viewport.size, style: style, resetToken: resetToken, isResizing: isResizing)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                                row(cue)
                                    .id(cue.id)
                                    .background {
                                        if !isResizing {
                                            GeometryReader { geometry in
                                                Color.clear.preference(key: UntimedRowFrames.self,
                                                    value: [index: geometry.frame(in: .named(coordinateSpace))])
                                            }
                                        }
                                        SubtitleRowMarker(id: cue.id, anchor: rowAnchor)
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                            }
                        }
                        .frame(maxWidth: 760)
                        .padding(.horizontal, horizontalInset)
                        .padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("subtitleReadViewport")
                    .scrollDisabled(isResizing)
                    .coordinateSpace(name: coordinateSpace)
                    .mask { SubtitleViewportFade() }
                    .onPreferenceChange(UntimedRowFrames.self) { value in
                        guard !isResizing, value != frames else { return }
                        frames = value
                        recordVisibleRow(layout: layout)
                    }
                    .onScrollPhaseChange { _, phase in
                        guard !isResizing else { return }
                        if phase == .tracking || phase == .interacting {
                            userInterrupted = true
                            ready = true
                            restoredLayout = layout
                        }
                        if phase == .idle {
                            recordVisibleRow(layout: layout)
                            session.flush()
                        }
                    }
                    .task(id: layout) {
                        // 连续拖动只重排文字，不用中间尺寸恢复或覆盖原阅读位置。
                        guard !isResizing else { ready = false; return }
                        await restore(using: proxy, layout: layout)
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase != .active { session.flush() }
                    }
                    .onDisappear { session.flush() }
                }
            }
        }
    }

    private func recordVisibleRow(layout: ReadingLayout) {
        guard !isResizing, ready, restoredLayout == layout else { return }
        // 在渐隐下方取第一条仍可读的台词；整页像素不参与持久保存。
        guard let entry = frames.filter({ $0.value.maxY > 28 && $0.value.minY < layout.size.height - 22 })
            .min(by: { $0.key < $1.key }), entry.value.height > 0 else { return }
        session.record(index: entry.key, fraction: Double(max(0, 28 - entry.value.minY) / entry.value.height))
    }

    private func restore(using proxy: ScrollViewProxy, layout: ReadingLayout) async {
        ready = false
        userInterrupted = false
        if lastResetToken != resetToken {
            session.latest = ScriptReadingPosition(cues: cues, index: 0)
            session.flush()
            lastResetToken = resetToken
        }
        let position = session.latest
        if let position, let index = position.resolvedIndex(in: cues) {
            let id = cues[index].id
            var restored = false
            for attempt in 0..<16 {
                guard !Task.isCancelled, !userInterrupted else { return }
                switch rowAnchor.restoreReading(id: id, fraction: position.fraction) {
                case .aligned:
                    // 再等一次布局稳定，不能用暂时的首屏覆盖旧记录。
                    do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
                    if case .aligned = rowAnchor.restoreReading(id: id, fraction: position.fraction) {
                        restored = true
                    }
                case .moved:
                    break
                case .missingRow:
                    if attempt == 0 || attempt == 4 || attempt == 10 { proxy.scrollTo(id, anchor: .top) }
                case .interacting:
                    break
                }
                if restored { break }
                // LazyVStack 的远处行先加载，第二次排版完成后再校准页内位置。
                do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
            }
            guard !Task.isCancelled, !userInterrupted else { return }
            guard restored else {
                session.errorMessage = L10n.text("暂未定位到上次阅读处；手动翻阅后会记住新位置。")
                return
            }
        }
        guard !Task.isCancelled else { return }
        restoredLayout = layout
        ready = true
        recordVisibleRow(layout: layout)
        session.flush()
    }
}

private struct ReadingLayout: Equatable {
    let size: CGSize
    let style: SubtitleStyle
    let resetToken: UUID
    let isResizing: Bool
}

private struct UntimedRowFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
