import SwiftUI

/// 选区只引用当前字幕的顺序，音频保存使用确认时捕获的原曲和时间。
struct SubtitleClipReader: View {
    let cues: [SubtitleCue]
    let currentID: UUID?
    let readingID: UUID?
    let nearbyIndex: Int
    let style: SubtitleStyle
    let pageMidY: CGFloat
    let horizontalInset: CGFloat
    let durationMS: Int
    let resetToken: UUID
    @Binding var followPlayback: Bool
    var isResizing = false
    var viewportFocusFraction: CGFloat = 0
    var allowsSelection = true
    let onSeek: (SubtitleCue) -> Void
    let onConfirm: (SubtitleCue, SubtitleCue, Int, Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startIndex: Int?
    @State private var endIndex: Int?
    @State private var wasFollowing = true
    @State private var rowFrames: [Int: CGRect] = [:]
    @State private var activeBoundary: ClipBoundary?
    @State private var dragY: CGFloat?
    @State private var selectionCurrentID: UUID?
    @State private var selectionNearbyIndex = 0
    @State private var rowAnchor = SubtitleRowAnchor()
    @State private var focusRequest: ReaderFocusRequest?
    @State private var browsing: ReaderBrowsePhase = .following
    @State private var resizeSession: SubtitleResizeSession?

    private let coordinateSpace = "subtitleClipViewport"
    private let accent = Color(red: 0.84, green: 0.72, blue: 1)
    private var hasTimedCues: Bool { cues.contains(where: \.hasTiming) }
    private var selected: ClosedRange<Int>? {
        guard let startIndex, let endIndex else { return nil }
        return startIndex...endIndex
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                readerViewport(scroller)
            }
            if let selected { selectionControls(selected) }
        }
        .transaction { transaction in
            if startIndex != nil { transaction.animation = nil; transaction.disablesAnimations = true }
        }
        .onChange(of: resetToken) { _, _ in
            resizeSession = nil
            cancelSelection()
        }
        .onChange(of: cues) { _, _ in
            resizeSession = nil
            focusRequest = nil
            cancelSelection()
        }
    }

    private func readerViewport(_ scroller: ScrollViewProxy) -> some View {
        GeometryReader { viewport in
            let focus = SubtitleScrollFocus(pageMidY: pageMidY, viewport: viewport.frame(in: .global), viewportFocusFraction: viewportFocusFraction)
            let contentFocus = isResizing ? (resizeSession?.focus ?? focus) : focus
            ZStack(alignment: .topLeading) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
                            row(cue, at: index, scroller: scroller)
                                .id(cue.id)
                                .background {
                                    if !isResizing {
                                        GeometryReader { geometry in
                                            Color.clear.preference(key: SubtitleRowFrames.self,
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
                    .padding(.top, hasTimedCues ? contentFocus.topPadding : 28)
                    .padding(.bottom, hasTimedCues ? contentFocus.bottomPadding : 28)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("subtitleReadViewport")
                .scrollDisabled(activeBoundary != nil || isResizing)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                    #if DEBUG
                    if CommandLine.arguments.contains("-clipDragTrace"), activeBoundary != nil {
                        DebugLog.write("clip-drag scroll-y=\(y)")
                    }
                    #endif
                }
                .onPreferenceChange(SubtitleRowFrames.self) { frames in
                    // 手指按住时冻结坐标，避免布局回传与选句互相驱动。
                    guard activeBoundary == nil, !isResizing, frames != rowFrames else { return }
                    rowFrames = frames
                }
                .onScrollPhaseChange { _, phase in
                    guard !isResizing else { return }
                    if phase == .tracking || phase == .interacting {
                        // 用户重新翻阅时，停止尚未完成的松手校正。
                        resizeSession = nil
                        focusRequest = nil
                        if followPlayback && startIndex == nil { browsing = .byHand }
                    } else if phase == .idle, browsing == .byHand {
                        browsing = .waiting
                    }
                }
                .mask { SubtitleViewportFade() }
                ForEach(ClipBoundary.allCases, id: \.self) { boundary in
                    if startIndex != nil, endIndex != nil {
                        let positions = handlePositions(height: viewport.size.height)
                        let y = boundary == .start ? positions.start : positions.end
                        boundaryHandle(boundary, scroller: scroller)
                            .frame(width: min(max(0, viewport.size.width - 2 * horizontalInset), 760), height: 44)
                            .position(x: viewport.size.width / 2,
                                      y: min(max(y, 22), max(22, viewport.size.height - 22)))
                            .highPriorityGesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                                    .onChanged { value in
                                        #if DEBUG
                                        if activeBoundary == nil, CommandLine.arguments.contains("-clipDragTrace") {
                                            DebugLog.write("clip-drag begin")
                                        }
                                        #endif
                                        activeBoundary = boundary
                                        dragY = value.location.y
                                        moveBoundary(boundary, to: value.location.y)
                                    }
                                    .onEnded { value in
                                        moveBoundary(boundary, to: value.location.y)
                                        #if DEBUG
                                        if CommandLine.arguments.contains("-clipDragTrace") { DebugLog.write("clip-drag end") }
                                        #endif
                                        dragY = nil; activeBoundary = nil
                                    }
                            )
                    }
                }
            }
            .coordinateSpace(name: coordinateSpace)
            .clipped()
            .onChange(of: readingID, initial: true) { old, id in
                if followPlayback && browsing == .following { requestCenter(id, animated: old != nil) }
            }
            .onChange(of: followPlayback) { _, following in
                browsing = .following
                if !isResizing { resizeSession = nil }
                if following { requestCenter(readingID, animated: true) }
                else { focusRequest = nil }
            }
            .onChange(of: focus) {
                if followPlayback && browsing == .following { requestCenter(readingID) }
            }
            .onChange(of: isResizing) { _, resizing in
                if resizing {
                    focusRequest = nil
                    rowAnchor.stopScrolling()
                    // 快速再次按下时沿用尚未恢复完的阅读锚点；新轮次拥有新的编号。
                    resizeSession = SubtitleResizeSession(
                        position: resizeSession?.position ?? rowAnchor.captureReading(ids: cues.map(\.id)),
                        focus: focus)
                }
            }
            .task(id: isResizing ? nil : resizeSession?.id) {
                guard !isResizing, let session = resizeSession else { return }
                if !(followPlayback && browsing == .following && startIndex == nil),
                   let position = session.position {
                    await rowAnchor.restore(position, using: scroller)
                }
                // 旧任务取消返回后不能清掉新一轮的位置，也不能恢复自动跟随。
                guard !Task.isCancelled, !isResizing, resizeSession?.id == session.id else { return }
                resizeSession = nil
                if followPlayback && browsing == .following { requestCenter(readingID) }
            }
            .task(id: ReaderWaitState(phase: browsing, resizing: isResizing, settling: resizeSession != nil)) {
                guard browsing == .waiting, !isResizing, resizeSession == nil else { return }
                do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
                browsing = .following
            }
            .onChange(of: browsing) { old, phase in
                if old == .waiting, phase == .following, followPlayback {
                    requestCenter(readingID, animated: true)
                }
            }
            .task(id: focusRequest) {
                if let request = focusRequest {
                    await center(request, in: focus, scroller: scroller)
                }
            }
        }
    }

    private func requestCenter(_ id: UUID?, animated: Bool = false) {
        guard !isResizing, resizeSession == nil, startIndex == nil, let id else { focusRequest = nil; return }
        focusRequest = ReaderFocusRequest(cueID: id, animated: animated && !reduceMotion)
    }

    /// 只在定位或松手回归时测量。对看得到的行直接滚到点位，远处的行先按 ID 装入。
    private func center(_ request: ReaderFocusRequest, in focus: SubtitleScrollFocus, scroller: ScrollViewProxy) async {
        guard let index = cues.firstIndex(where: { $0.id == request.cueID }) else { return }
        var requestedLayout = false
        var alignedOnce = false
        for attempt in 0..<8 {
            guard !Task.isCancelled, !isResizing, resizeSession == nil, request == focusRequest, startIndex == nil else { return }
            let delay: Int
            switch rowAnchor.center(id: request.cueID, animated: request.animated, targetY: viewportFocusFraction > 0 ? focus.targetY : nil) {
            case .aligned:
                if alignedOnce { return }
                alignedOnce = true
                delay = 350 // 转屏或远跳后，再核对一次最终布局。
            case .moved:
                alignedOnce = false
                delay = request.animated ? 480 : 60
            case .interacting:
                delay = 90
            case .missingRow:
                if !requestedLayout, rowFrames[index] == nil || attempt >= 2 {
                    requestedLayout = true
                    withAnimation(request.animated ? .easeOut(duration: 0.32) : nil) {
                        scroller.scrollTo(request.cueID, anchor: focus.anchor(rowHeight: rowFrames[index]?.height ?? 44))
                    }
                }
                delay = requestedLayout && request.animated ? 320 : 45
            }
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
        }
    }

    private func row(_ cue: SubtitleCue, at index: Int, scroller: ScrollViewProxy) -> some View {
        let chosen = selected?.contains(index) == true
        let isCurrent = cue.id == (startIndex == nil ? currentID : selectionCurrentID)
        let opacity: Double = !cue.hasTiming ? 0.85 : chosen || isCurrent ? 1 : (abs(cue.index - (startIndex == nil ? nearbyIndex : selectionNearbyIndex)) < 2 ? 0.77 : 0.56)
        return HStack(alignment: .center, spacing: 8) {
            Text(cue.hasTiming ? SubtitleTime.clock(cue.startMS) : "")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 40, alignment: .leading)
                .accessibilityHidden(true)
            Button {
                if let startIndex { if index >= startIndex && canSelect(cue) { endIndex = index } }
                else {
                    resizeSession = nil
                    if cue.hasTiming { requestCenter(cue.id, animated: true) }
                    onSeek(cue)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if style.showOriginal || (!cue.hasTiming && (cue.translatedText ?? "").isEmpty) {
                        Text(cue.text).font(.system(size: style.fontSize + 3, weight: isCurrent ? .bold : .semibold))
                    }
                    if style.showTranslation, let translation = cue.translatedText, !translation.isEmpty {
                        Text(translation).font(.system(size: style.fontSize, weight: isCurrent ? .semibold : .regular))
                    }
                }
                .foregroundStyle(.white.opacity(opacity))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("subtitleCue-\(index)")
            .accessibilityLabel("\(cue.hasTiming ? SubtitleTime.clock(cue.startMS) : L10n.text("未打轴"))，\(cue.displayText)")
            Color.clear.frame(width: 44, height: 1)
                .overlay {
                    if isCurrent && startIndex == nil && canSelect(cue) {
                        Button { beginSelection(at: index, scroller: scroller) } label: {
                            Image(systemName: "scissors")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("subtitleScissors-\(index)")
                        .accessibilityLabel("从第 \(index + 1) 句开始摘取")
                        .disabled(!canSelect(cue))
                    }
                }

        }
        .padding(.vertical, 11)
        .background(chosen ? accent.opacity(0.13) : (isCurrent ? .white.opacity(0.05) : .clear),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    /// 离屏边界停靠在视窗边缘，长选区仍能调整两端。
    private func handlePositions(height: CGFloat) -> (start: CGFloat, end: CGFloat) {
        func position(_ boundary: ClipBoundary, index: Int?) -> CGFloat {
            if activeBoundary == boundary, let dragY { return dragY }
            guard let index else { return 0 }
            if let frame = rowFrames[index] { return boundary == .start ? frame.minY : frame.maxY }
            return index < (rowFrames.keys.min() ?? index) ? 0 : height
        }
        let bottom = max(22, height - 22)
        var start = min(max(position(.start, index: startIndex), 22), bottom)
        var end = min(max(position(.end, index: endIndex), 22), bottom)
        if end - start < 44 {
            if start <= 22 { end = min(bottom, start + 44) }
            else { start = max(22, end - 44) }
        }
        return (start, end)
    }

    private func boundaryHandle(_ boundary: ClipBoundary, scroller: ScrollViewProxy) -> some View {
        ClipDashedLine(color: accent, icon: "line.3.horizontal")
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(boundary == .start ? L10n.text("拖动选择开始台词") : L10n.text("拖动选择结束台词"))
            .accessibilityIdentifier(boundary == .start ? "subtitleClipStart" : "subtitleClipEnd")
            .accessibilityValue((boundary == .start ? startIndex : endIndex).map { L10n.text("第 \($0 + 1) 句") } ?? "")
            .accessibilityAdjustableAction { direction in
                guard let startIndex, let endIndex else { return }
                let current = boundary == .start ? startIndex : endIndex
                let candidates = cues.indices.filter {
                    canSelect(cues[$0]) && (boundary == .start ? $0 <= endIndex : $0 >= startIndex)
                }
                let next: Int?
                switch direction {
                case .increment: next = candidates.first { $0 > current }
                case .decrement: next = candidates.last { $0 < current }
                @unknown default: next = nil
                }
                if let next {
                    if boundary == .start { self.startIndex = next } else { self.endIndex = next }
                    scroller.scrollTo(cues[next].id, anchor: boundary == .start ? .top : .bottom)
                }
            }
    }

    private func selectionControls(_ selection: ClosedRange<Int>) -> some View {
        VStack(spacing: 8) {
            Text("拖动虚线选句；松手后滑动台词可跨屏")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { cancelSelection() }
                    .frame(minWidth: 58, minHeight: 34, alignment: .leading)
                    .accessibilityIdentifier("cancelSubtitleClip")
                Spacer()
                Text("已选 \(selection.count) 句").font(.subheadline.monospacedDigit())
                Spacer()
                Button("确定") {
                    let first = cues[selection.lowerBound]
                    let last = cues[selection.upperBound]
                    let end = min(durationMS, cues[selection].filter(canSelect).map(\.endMS).max() ?? last.endMS)
                    onConfirm(first, last, max(0, first.startMS), end)
                }
                .frame(minWidth: 58, minHeight: 34, alignment: .trailing)
                .accessibilityIdentifier("confirmSubtitleClip")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, horizontalInset)
        .padding(.bottom, 16)
    }

    private func canSelect(_ cue: SubtitleCue) -> Bool {
        allowsSelection && cue.hasTiming && cue.startMS < durationMS
    }

    private func beginSelection(at index: Int, scroller: ScrollViewProxy) {
        guard canSelect(cues[index]) else { return }
        resizeSession = nil
        focusRequest = nil
        if startIndex == nil { wasFollowing = followPlayback }
        followPlayback = false
        selectionCurrentID = currentID
        selectionNearbyIndex = nearbyIndex
        startIndex = index; endIndex = index
        scroller.scrollTo(cues[index].id, anchor: .center)
    }

    private func moveBoundary(_ boundary: ClipBoundary, to y: CGFloat) {
        guard let startIndex, let endIndex else { return }
        let candidates = rowFrames.filter {
            cues.indices.contains($0.key) && canSelect(cues[$0.key])
                && (boundary == .start ? $0.key <= endIndex : $0.key >= startIndex)
        }
        func distance(_ frame: CGRect) -> CGFloat {
            abs((boundary == .start ? frame.minY : frame.maxY) - y)
        }
        if let nearest = candidates.min(by: { distance($0.value) < distance($1.value) }) {
            if boundary == .start { self.startIndex = nearest.key } else { self.endIndex = nearest.key }
        }
    }

    private func cancelSelection() {
        guard startIndex != nil else { return }
        startIndex = nil; endIndex = nil; dragY = nil; activeBoundary = nil
        followPlayback = wasFollowing
    }
}

/// 仅让滚动的文字淡入封面背景；把手、提示和工具栏在遮罩外。
struct SubtitleViewportFade: View {
    var body: some View {
        GeometryReader { viewport in
            let edge = min(22, viewport.size.height * 0.10)
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom)
                    .frame(height: edge)
                Color.white
                LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: edge)
            }
        }
    }
}

private enum ClipBoundary: CaseIterable { case start, end }
private enum ReaderBrowsePhase { case following, byHand, waiting }

private struct ReaderFocusRequest: Equatable {
    let cueID: UUID
    let animated: Bool
    // 再次点击同一句时也要回到这句的位置。
    let requestID = UUID()
}

private struct SubtitleRowFrames: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ClipDashedLine: View {
    let color: Color
    let icon: String
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 4, height: 4).clipShape(Circle())
            DashedRule().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).frame(height: 1)
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 24)
                .background(Color(red: 0.25, green: 0.19, blue: 0.37), in: Capsule())
        }
        .foregroundStyle(color)
    }
}
private struct DashedRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in path.move(to: CGPoint(x: 0, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}

private struct ReaderWaitState: Equatable {
    let phase: ReaderBrowsePhase
    let resizing: Bool
    let settling: Bool
}
