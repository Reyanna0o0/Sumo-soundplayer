import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 全屏字幕页：整段滚动、当前句高亮、可编辑、可导出。
struct SubtitlePageView: View {
    @EnvironmentObject private var subtitles: SubtitleController
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var pictureInPicture: AppPictureInPictureCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let coverPath: String?
    let trackID: Int64
    let favoriteWork: WorkRecord?
    let onFavorite: (WorkRecord) -> Void
    let clipSavedToken: UUID
    let onClipRequest: (SubtitleClipDraft) -> Void

    @State private var followPlayback = true
    @State private var showStylePanel = false
    @State private var isEditing = false
    @State private var editingFeedback: String?
    @State private var editingTarget: EditingTarget?
    @State private var quickEditing: EditingTarget?
    @State private var quickText = ""
    @State private var quickTranslation = ""
    @State private var quickDraftError: String?
    @FocusState private var quickFocus: QuickSubtitleField?
    @State private var showVersions = false
    @State private var exportURL: URL?
    @State private var exportRequest: SubtitleExportRequest?
    @State private var showSubtitleImporter = false
    @State private var importMessage: String?
    @State private var subtitleReceipt: SubtitleImportReceipt?
    @State private var clipSaved = false
    @State private var subtitleSources: [SubtitleTrackRecord] = []
    @State private var measuredEditRow: EditRowSize?
    @State private var readingResetToken = UUID()
    @State private var portraitDivision: CGFloat = 0
    @State private var landscapeDivision: CGFloat = 0
    @State private var resizingReader = false
    @GestureState private var dividerDragging = false
    @State private var dividerDragStart: CGFloat?
    @State private var dividerActivity = UUID()
    @State private var editRowAnchor = SubtitleRowAnchor()
    @State private var editResizeSession: SubtitleResizeSession?
    @State private var editReadingSession: ScriptReadingSession?
    @State private var editReadingReady = false
    @StateObject private var inlineKeyboard = SubtitleInlineKeyboard()
    @StateObject private var editor = SubtitleEditorController()

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height && proxy.size.width >= 560
            let originalLayout = SubtitleReaderLayout(size: proxy.size, value: landscape ? landscapeDivision : portraitDivision)
            let lift = landscape ? 0 : inlineKeyboard.temporaryLift
            let layout = SubtitleReaderLayout(size: proxy.size,
                value: originalLayout.value(at: max(originalLayout.minimum, originalLayout.boundary - lift)))
            let pageMidY = proxy.frame(in: .global).midY + (proxy.safeAreaInsets.bottom - proxy.safeAreaInsets.top) / 2
            ZStack(alignment: .topLeading) {
                backdrop(layout: layout, safeFrame: proxy.frame(in: .global))
                VStack(spacing: 0) {
                    if !landscape { Spacer().frame(height: layout.readerTop) }
                    content(pageMidY: pageMidY, horizontalInset: landscape ? 8 : 24, viewportFocusFraction: abs(layout.value))
                    readerControls
                }
                .padding(.leading, layout.readerLeading)
                divider(layout: layout).allowsHitTesting(quickEditing == nil)

                Button { dismiss() } label: {
                    Label("返回单行字幕", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(.white)
                .accessibilityIdentifier("collapseSubtitles")
                .disabled(quickEditing != nil)
                .padding(.leading, 12)
                .padding(.top, 4)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { revealDivider() })
            .onChange(of: SubtitleInlineKeyboard.Configuration(editing: quickEditing != nil,
                field: quickFocus == .translation ? .translation : .original,
                appliedLift: originalLayout.boundary - layout.boundary,
                maximumLift: landscape ? 0 : originalLayout.boundary - originalLayout.minimum), initial: true) { _, value in
                    inlineKeyboard.configure(value)
                }
            .onChange(of: landscape) { _, _ in
                resizingReader = false
                dividerDragStart = nil
                revealDivider()
            }
        }
        // Keep the cover, reader partition and bottom transport at their original screen positions.
        // Only the inline list manages the part that the keyboard actually covers.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onChange(of: dividerDragging) { _, dragging in
            // GestureState 也会在系统取消手势时复位，不能只依赖 onEnded。
            if !dragging { finishDividerDrag() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                finishDividerDrag()
                recordEditingReadingPosition()
                editReadingSession?.flush()
            }
        }
        .onAppear { pictureInPicture.pageVisibility(.subtitles, visible: true) }
        .onDisappear {
            recordEditingReadingPosition()
            editReadingSession?.flush()
            finishDividerDrag()
            pictureInPicture.pageVisibility(.subtitles, visible: false)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(quickEditing != nil)
        .sheet(isPresented: $showStylePanel) { SubtitleStyleSheet(mode: .fullScreen) }
        .sheet(isPresented: $pictureInPicture.isSubtitleSheetPresented, onDismiss: {
            pictureInPicture.pageVisibility(.subtitles, visible: true)
        }) { SubtitlePictureInPictureSheet() }
        .sheet(isPresented: $showVersions) { versionSheet }
        .fileImporter(
            isPresented: $showSubtitleImporter,
            allowedContentTypes: subtitleTypes,
            allowsMultipleSelection: false
        ) { result in
            handleSubtitleImport(result)
        }
        .alert(showClearConfirm ? L10n.text("清除字幕？") : L10n.text("字幕提示"), isPresented: Binding(
            get: { showClearConfirm || importMessage != nil },
            set: { if !$0 { showClearConfirm = false; importMessage = nil } }
        )) {
            if showClearConfirm {
                Button("取消", role: .cancel) { showClearConfirm = false }
                Button("清除", role: .destructive) {
                    if isCurrentTrack, let repository = store.subtitleRepository {
                        subtitles.clearAll(repository: repository)
                        editor.load(trackID: 0)
                        refreshSubtitleSources()
                    }
                    showClearConfirm = false
                }
            } else {
                Button("好") { importMessage = nil }
            }
        } message: {
            Text(showClearConfirm
                 ? L10n.text("会删除这个曲目的全部字幕和所有版本，无法恢复。音频文件不受影响。")
                 : (importMessage ?? ""))
        }
        .subtitleImportReceipt($subtitleReceipt)
        .onChange(of: clipSavedToken) { _, _ in clipSaved = true }
        .onChange(of: isEditing) { _, editing in
            editResizeSession = nil
            if !editing {
                editReadingSession?.flush()
                editReadingSession = nil
                editReadingReady = false
            }
        }
        .onChange(of: subtitles.cues) { _, _ in editResizeSession = nil }
        .onChange(of: quickText) { _, _ in persistQuickDraft(); inlineKeyboard.requestUpdate(reveal: true) }
        .onChange(of: quickTranslation) { _, _ in persistQuickDraft(); inlineKeyboard.requestUpdate(reveal: true) }
        .sheet(item: $editingTarget) { initialTarget in
            // The presentation identity stays stable while continuing; read the
            // live target instead of retaining the first row captured by the sheet.
            editSheet(for: editingTarget ?? initialTarget)
        }
        .sheet(item: $exportRequest) { request in
            SubtitleFileDestination(url: request.url) { exportRequest = nil }
        }
        .task(id: trackID) { attachEditor() }
    }

    private var hasUntimedCues: Bool { subtitles.cues.contains { !$0.hasTiming } }

    private var isCurrentTrack: Bool {
        player.currentItem?.trackID == trackID && player.currentItem?.isSavedClip == false
    }

    private var isCurrentPlayback: Bool { player.currentItem?.trackID == trackID }
    private var isSavedClip: Bool { trackID < 0 }
    private var exportableCues: [SubtitleCue] { isSavedClip ? subtitles.cues : editor.cues }

    private func revealDivider() {
        dividerActivity = UUID()
    }

    private func finishDividerDrag() {
        guard resizingReader || dividerDragStart != nil else { return }
        dividerDragStart = nil
        resizingReader = false
        revealDivider()
    }

    private func divider(layout: SubtitleReaderLayout) -> some View {
        SubtitleDividerHandle(landscape: layout.landscape, activity: dividerActivity, resizing: resizingReader)
            .frame(width: layout.landscape ? 44 : 76, height: layout.landscape ? 92 : 44)
            .contentShape(Rectangle())
            .position(x: layout.landscape ? layout.boundary - 4 : layout.size.width / 2,
                      y: layout.landscape ? layout.size.height / 2 : layout.boundary - 8)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($dividerDragging) { _, active, _ in active = true }
                .onChanged { value in
                    if dividerDragStart == nil {
                        dividerDragStart = layout.boundary
                        resizingReader = true
                        revealDivider()
                    }
                    let movement = layout.landscape ? value.translation.width : value.translation.height
                    setDivision(layout.value(at: (dividerDragStart ?? layout.boundary) + movement), landscape: layout.landscape)
                }
                .onEnded { _ in finishDividerDrag() })
            .accessibilityRepresentation {
                Slider(value: Binding(
                    get: { Double((layout.value + 1) * 50) },
                    set: { setDivision(CGFloat($0 / 50 - 1), landscape: layout.landscape); revealDivider() }
                ), in: 0...100, step: 5) { Text("封面与台词分界") }
                .accessibilityValue(Text(verbatim: "\(Int((layout.value + 1) * 50))%"))
                .accessibilityIdentifier("subtitleDivider")
            }
    }

    private func setDivision(_ value: CGFloat, landscape: Bool) {
        if landscape { landscapeDivision = value }
        else { portraitDivision = value }
    }

    private func backdrop(layout: SubtitleReaderLayout, safeFrame: CGRect) -> some View {
        GeometryReader { canvas in
            let size = canvas.size
            let origin = canvas.frame(in: .global).origin
            let amount = layout.framingFraction
            let margin = 22 * amount
            let top = max(0, safeFrame.minY - origin.y + 52) * amount
            ZStack(alignment: .topLeading) {
                Color.black
                CoverImageView(path: coverPath, cornerRadius: 0, maxPixels: 1600, showsOriginal: true)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 32)
                if layout.landscape {
                    LinearGradient(stops: [.init(color: .black.opacity(0.34), location: 0),
                                           .init(color: .black.opacity(0.39), location: 0.24),
                                           .init(color: .black.opacity(0.62), location: 0.46),
                                           .init(color: .black.opacity(0.77), location: 0.68),
                                           .init(color: .black.opacity(0.80), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                    let left = max(0, safeFrame.minX - origin.x + 16) * amount
                    let edge = min(size.width, max(0, safeFrame.minX + layout.readerLeading - 8 - origin.x))
                    let width = max(1, edge - left - margin)
                    let height = max(1, size.height - top - max(16, size.height - (safeFrame.maxY - origin.y)) * amount)
                    let end = width / (width + margin)
                    CoverImageView(path: coverPath, cornerRadius: 0, contentMode: .fill,
                                   maxPixels: 1600, framingFraction: amount, showsOriginal: true)
                        .frame(width: width, height: height)
                        .padding(.trailing, margin)
                        .mask {
                            LinearGradient(stops: [.init(color: .white, location: 0.72 + (end - 0.72) * amount),
                                                   .init(color: .white.opacity(0.90), location: 0.79 + (end + (1 - end) * 0.25 - 0.79) * amount),
                                                   .init(color: .white.opacity(0.50), location: 0.86 + (end + (1 - end) * 0.50 - 0.86) * amount),
                                                   .init(color: .white.opacity(0.10), location: 0.94 + (end + (1 - end) * 0.80 - 0.94) * amount),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                        .offset(x: left, y: top)
                } else {
                    Color.black.opacity(0.77)
                    let delta = layout.boundary - layout.standard
                    let legacyEnd = size.height * 0.40 + delta
                    let completeEnd = safeFrame.minY - origin.y + layout.boundary - margin
                    let endY = legacyEnd + (completeEnd - legacyEnd) * amount
                    let height = max(1, endY - top)
                    let end = height / (height + margin)
                    // 向上收起时平移原渐变带，不按缩小后的亮图重新缩短它；
                    // 否则顶部提示会跑到尚未变暗的封面上。
                    let fadeStart = delta < 0
                        ? min(1, max(0, (size.height * 0.40 * 0.55 + delta) / height)) : 0.55
                    CoverImageView(path: coverPath, cornerRadius: 0, maxPixels: 1600,
                                   framingFraction: amount, showsOriginal: true)
                        .frame(width: max(1, size.width - 32 * amount), height: height)
                        .padding(.bottom, margin)
                        .mask {
                            LinearGradient(stops: [.init(color: .white, location: fadeStart + (end - fadeStart) * amount),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                        .offset(x: 16 * amount, y: top)
                }
            }
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(pageMidY: CGFloat, horizontalInset: CGFloat, viewportFocusFraction: CGFloat) -> some View {
        if let target = quickEditing, target.trackID != trackID || !editor.cues.indices.contains(target.index) {
            ScrollView {
                VStack(spacing: 12) {
                    Text("播放曲目或字幕已切换。文字草稿仍保留，可复制文字或取消后返回。")
                        .font(.callout).padding(.horizontal)
                    quickEditor(for: target)
                }
                .padding(.top, inlineKeyboard.topPadding)
                .padding(.bottom, 24 + inlineKeyboard.bottomPadding)
                .background(SubtitleKeyboardMarker(part: .content, avoidance: inlineKeyboard))
            }
            .scrollDismissesKeyboard(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loaded = subtitles.loadedTrackID, loaded != trackID {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if subtitles.cues.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if !isEditing && subtitles.isUntimed {
                    // 保留手动阅读的首行留白；状态说明统一放到播放控制上方。
                    Color.clear.frame(height: 28)
                }
                if subtitles.cues.contains(where: { $0.status == .provisional }) {
                    Text(isSavedClip ? L10n.text("部分台词沿用保存时的自动结束时间") : L10n.text("部分台词使用自动结束时间，可在编辑时调整"))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                        .accessibilityIdentifier("printedScriptNotice")
                }
                if isEditing && !hasUntimedCues { timelineHeader }
                if isEditing {
                    cueList(pageMidY: pageMidY, viewportFocusFraction: viewportFocusFraction)
                } else if subtitles.isUntimed, let sourceID = subtitles.loadedSubtitleTrackID {
                    UntimedScriptReader(cues: subtitles.cues, sourceID: sourceID,
                        repository: store.readingPositions, handoff: store.readingSessionHandoff, style: subtitles.style,
                        horizontalInset: horizontalInset, resetToken: readingResetToken, isResizing: resizingReader) { cue in
                        untimedRow(cue)
                    }
                    .id("\(sourceID)-\(subtitles.readingRevision)-\(isEditing)")
                } else {
                    if clipSaved {
                        Text("已保存到摘选").font(.caption).foregroundStyle(.secondary)
                    }
                    SubtitleClipReader(
                        cues: subtitles.cues, currentID: subtitles.currentCue?.id,
                        readingID: subtitles.readingCueID,
                        nearbyIndex: subtitles.currentCue?.index ?? subtitles.upcomingCue?.index ?? 0,
                        style: subtitles.style, pageMidY: pageMidY, horizontalInset: horizontalInset, durationMS: player.durationMS, resetToken: clipSavedToken,
                        followPlayback: $followPlayback, isResizing: resizingReader, viewportFocusFraction: viewportFocusFraction,
                        allowsSelection: !isSavedClip && player.hasCompleteLocalAudio,
                        onSeek: seekTo,
                        onConfirm: { first, last, start, end in
                            guard isCurrentTrack, player.hasCompleteLocalAudio, let item = player.currentItem else { return }
                            clipSaved = false
                            onClipRequest(SubtitleClipDraft(item: item, first: first, last: last,
                                durationMS: player.durationMS, startMS: start, endMS: end))
                        }
                    )
                }
                if isEditing {
                    VStack(spacing: 2) {
                        Text(editingFeedback ?? (quickEditing == nil
                            ? L10n.text("点按改字 · 长按详细编辑 · ＋ 空行即时保存")
                            : L10n.text("文字需点「保存文字」；取消放弃本次文字修改")))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("subtitleEditingFeedback")
                        if !hasUntimedCues {
                            Text("长按台词可调整时间，确认后保存")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.64))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, 4).padding(.bottom, 4)
                } else if hasUntimedCues {
                    Text(subtitles.hasTimedCues ? L10n.text("点已打轴的台词可跳转，点未打轴的台词可编辑") : L10n.text("台本尚未打轴 · 点击台词可编辑"))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, horizontalInset)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("untimedScriptNotice")
                }
            }
        }
    }

    /// 保持与有轴阅读相同的时间栏和剪刀栏留白。
    private func untimedRow(_ cue: SubtitleCue) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Color.clear.frame(width: 40, height: 1)
            Button { seekTo(cue) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if subtitles.style.showOriginal || (cue.translatedText ?? "").isEmpty {
                        Text(cue.text).font(.system(size: subtitles.style.fontSize + 3, weight: .semibold))
                    }
                    if subtitles.style.showTranslation, let translation = cue.translatedText, !translation.isEmpty {
                        Text(translation).font(.system(size: subtitles.style.fontSize))
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("subtitleCue-\(cue.index)")
            .accessibilityLabel("未打轴，\(cue.displayText)")
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.vertical, 11)
    }

    /// 波形只用于播放定位；字幕时间由逐句编辑面板确认保存。
    private var timelineHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            if player.isNetworkAudio {
                Text("网络试听暂不生成波形，需要完整本地文件。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            } else {
            WaveformView(
                timeline: WaveformTimeline(data: player.waveform),
                positionMS: player.positionMS,
                onSeek: { ms in
                    editResizeSession = nil
                    followPlayback = true
                    player.seek(to: ms)
                }
            )
            .padding(.horizontal, 10)
            .padding(.top, 4)
            }

        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("没有字幕", systemImage: "text.bubble")
        } description: {
            Text("有字幕文件时，可点底部「⋯」导入。整部作品的 PDF 或 TXT 台本可在作品详情的「⋯」菜单里按音轨配对。")
        }
    }

    private func cueList(pageMidY: CGFloat, viewportFocusFraction: CGFloat) -> some View {
        GeometryReader { viewport in
            let focus = SubtitleScrollFocus(pageMidY: pageMidY, viewport: viewport.frame(in: .global), viewportFocusFraction: viewportFocusFraction)
            ScrollViewReader { proxy in
                followedEditScroll(proxy: proxy, focus: focus, viewportSize: viewport.size)
            }
        }
    }

    private func editScrollContent(focus: SubtitleScrollFocus) -> some View {
        let contentFocus = resizingReader ? (editResizeSession?.focus ?? focus) : focus
        let current = currentEditingCueID
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(editor.cues) { cue in
                    rowView(for: cue)
                        .background {
                            SubtitleRowMarker(id: cue.id, anchor: editRowAnchor)
                            if cue.id == current, !resizingReader {
                                GeometryReader { row in
                                    Color.clear.preference(key: EditRowSizeKey.self,
                                        value: EditRowSize(id: cue.id, height: row.size.height))
                                }
                            }
                        }
                }
            }
            .padding(.top, (subtitles.hasTimedCues ? contentFocus.topPadding : 24) + inlineKeyboard.topPadding)
            .padding(.bottom, (subtitles.hasTimedCues ? contentFocus.bottomPadding : 24) + inlineKeyboard.bottomPadding)
            .background(SubtitleKeyboardMarker(part: .content, avoidance: inlineKeyboard))
        }
        .accessibilityIdentifier("subtitleEditViewport")
        .mask { SubtitleViewportFade() }
        .scrollDisabled(resizingReader)
        .scrollDismissesKeyboard(.never)
    }

    private func keyboardEditScroll(proxy: ScrollViewProxy, focus: SubtitleScrollFocus, viewportSize: CGSize) -> some View {
        editScrollContent(focus: focus)
            .onChange(of: quickEditing?.id, initial: true) { _, _ in
                if quickEditing != nil { inlineKeyboard.requestUpdate(reveal: true) }
                else {
                    inlineKeyboard.cancelFormMount()
                    editReadingReady = editReadingSession?.sourceID == editor.subtitleTrackID
                }
            }
            .task(id: quickEditing?.id) {
                guard let target = quickEditing, target.trackID == trackID else { return }
                await Task.yield()
                guard !Task.isCancelled, quickEditing?.id == target.id else { return }
                // First mount a restored distant draft or a newly inserted offscreen row.
                // An already mounted form keeps its position; no fixed top anchor is used.
                if !inlineKeyboard.hasMountedForm, editor.cues.indices.contains(target.index) {
                    let rowID = editor.cues[target.index].id
                    let sourceVersionID = editor.activeVersionID
                    inlineKeyboard.mountFormWhenReady {
                        guard quickEditing?.id == target.id, quickEditing?.versionID == target.versionID,
                              target.trackID == trackID, editor.activeVersionID == sourceVersionID,
                              editor.cues.indices.contains(target.index), editor.cues[target.index].id == rowID else { return }
                        proxy.scrollTo(rowID)
                    }
                }
                inlineKeyboard.requestUpdate(reveal: true)
            }
            .onChange(of: viewportSize) { _, _ in inlineKeyboard.requestUpdate(reveal: true) }
            .onChange(of: quickFocus) { _, field in inlineKeyboard.requestUpdate(reveal: field != nil) }
            .task(id: editor.subtitleTrackID) { await restoreEditingPosition(using: proxy) }
            .onScrollPhaseChange { _, phase in
                guard quickEditing == nil, !resizingReader else { return }
                if phase == .tracking || phase == .interacting { editReadingReady = true }
                if phase == .idle {
                    recordEditingReadingPosition()
                    editReadingSession?.flush()
                }
            }
            .onDisappear {
                inlineKeyboard.cancelFormMount()
                recordEditingReadingPosition()
                editReadingSession?.flush()
            }
    }

    private func followedEditScroll(proxy: ScrollViewProxy, focus: SubtitleScrollFocus, viewportSize: CGSize) -> some View {
        let current = currentEditingCueID
        return keyboardEditScroll(proxy: proxy, focus: focus, viewportSize: viewportSize)
            .onChange(of: current, initial: true) { old, _ in
                withAnimation(old == nil ? nil : .easeInOut(duration: 0.25)) { centerEditRow(using: proxy, focus: focus) }
            }
            .onChange(of: resizingReader) { _, resizing in
                if resizing {
                    editRowAnchor.stopScrolling()
                    editResizeSession = SubtitleResizeSession(
                        position: editResizeSession?.position ?? editRowAnchor.captureReading(ids: editor.cues.map(\.id)), focus: focus)
                }
            }
            .task(id: resizingReader ? nil : editResizeSession?.id) {
                guard !resizingReader, let session = editResizeSession else { return }
                if !followPlayback, let position = session.position { await editRowAnchor.restore(position, using: proxy) }
                guard !Task.isCancelled, !resizingReader, editResizeSession?.id == session.id else { return }
                editResizeSession = nil
                centerEditRow(using: proxy, focus: focus)
            }
            .onChange(of: followPlayback) {
                if !resizingReader { editResizeSession = nil }
                centerEditRow(using: proxy, focus: focus)
            }
            .onChange(of: focus) { centerEditRow(using: proxy, focus: focus) }
            .onPreferenceChange(EditRowSizeKey.self) { size in
                guard !resizingReader, let size, size.id == current, size != measuredEditRow else { return }
                measuredEditRow = size
                if quickEditing == nil && followPlayback && editResizeSession == nil {
                    proxy.scrollTo(size.id, anchor: focus.anchor(rowHeight: size.height))
                }
            }
    }

    private func centerEditRow(using proxy: ScrollViewProxy, focus: SubtitleScrollFocus) {
        guard quickEditing == nil, followPlayback, !resizingReader, editResizeSession == nil, let id = currentEditingCueID else { return }
        let height = measuredEditRow?.id == id ? measuredEditRow?.height : nil
        proxy.scrollTo(id, anchor: focus.anchor(rowHeight: height ?? 60))
    }

    private var currentEditingCueID: UUID? {
        guard let index = subtitles.currentCue?.index, editor.cues.indices.contains(index) else { return nil }
        return editor.cues[index].id
    }

    private func restoreEditingPosition(using proxy: ScrollViewProxy) async {
        editReadingReady = false
        guard !subtitles.hasTimedCues, let sourceID = editor.subtitleTrackID else { return }
        if editReadingSession?.sourceID != sourceID {
            editReadingSession?.flush()
            editReadingSession = ScriptReadingSession(sourceID: sourceID, cues: editor.cues,
                repository: store.readingPositions, handoff: store.readingSessionHandoff)
        }
        guard quickEditing == nil else { return }
        if let position = editReadingSession?.latest,
           let index = position.resolvedIndex(in: editor.cues), editor.cues.indices.contains(index) {
            await editRowAnchor.restore(SubtitleRowAnchor.ReadingPosition(id: editor.cues[index].id, fraction: position.fraction), using: proxy)
        }
        guard !Task.isCancelled, quickEditing == nil else { return }
        editReadingReady = true
    }

    private func recordEditingReadingPosition() {
        guard isEditing, quickEditing == nil, !subtitles.hasTimedCues, !resizingReader,
              editReadingReady, let session = editReadingSession,
              session.sourceID == editor.subtitleTrackID,
              let position = editRowAnchor.captureReading(ids: editor.cues.map(\.id)),
              let index = editor.cues.firstIndex(where: { $0.id == position.id }) else { return }
        session.record(cues: editor.cues, index: index, fraction: position.fraction)
    }

    private func rowView(for cue: SubtitleCue) -> some View {
        let current = subtitles.currentCue
        let distance = abs((current?.index ?? subtitles.upcomingCue?.index ?? cue.index) - cue.index)
        return Group {
            if let target = quickEditing, target.index == cue.index {
                VStack(spacing: 0) {
                    quickEditor(for: target)
                    insertControl(after: cue)
                }
            } else {
                SubtitleCueRow(cue: cue, isCurrent: current?.index == cue.index,
                               distance: distance, editing: isEditing, style: subtitles.style)
                    .padding(.trailing, 52)
                    .gesture(LongPressGesture(minimumDuration: 0.5).exclusively(before: TapGesture())
                        .onEnded { result in
                            guard quickEditing == nil else { return }
                            switch result {
                            case .first: openEditor(for: cue)
                            case .second: beginQuickEdit(cue)
                            }
                        })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(cue.isEmpty ? L10n.text("空白字幕") : cue.displayText)
                    .accessibilityValue(cue.hasTiming ? SubtitleTime.clock(cue.startMS) : L10n.text("未打轴"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { beginQuickEdit(cue) }
                    .accessibilityAction(named: L10n.text("详细编辑")) { openEditor(for: cue) }
                    .accessibilityIdentifier("editSubtitleCue-\(cue.index)")
                    .padding(.bottom, 16)
                    .overlay(alignment: .bottom) { insertControl(after: cue) }
            }
        }
        .id(cue.id)
    }

    private func insertControl(after cue: SubtitleCue) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
                .allowsHitTesting(false)
            Button { insertBlankLine(after: cue) } label: {
                Image(systemName: "plus").font(.system(size: 14)).frame(width: 44, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在第 \(cue.index + 1) 行下方增加空白字幕")
            .accessibilityIdentifier("insertSubtitleAfter-\(cue.index)")
            .disabled(quickEditing != nil)
        }
        .padding(.leading, 20).padding(.trailing, 8)
    }

    private func quickEditor(for target: EditingTarget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if target.versionID != editor.activeVersionID {
                Text("字幕版本已变更，这份文字草稿仍保留。可复制文字，取消后再编辑当前版本。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text(target.draft.hasTiming ? SubtitleTime.clock(target.draft.startMS) : L10n.text("未打轴"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("详细编辑") {
                    do { try SubtitleQuickDraftStore().remove(for: target.trackID) }
                    catch {
                        quickDraftError = L10n.text("旧草稿未能清除，当前文字仍保留在这里；暂未打开详细编辑。")
                        return
                    }
                    quickFocus = nil
                    editingFeedback = nil
                    var draft = target.draft
                    draft.text = quickText
                    draft.translatedText = quickTranslation.isEmpty ? nil : quickTranslation
                    quickDraftError = nil
                    quickEditing = nil
                    editingTarget = EditingTarget(trackID: target.trackID, index: target.index, versionID: target.versionID,
                                                  inserting: false, draft: draft)
                }
                .disabled(target.trackID != trackID || !isCurrentTrack || target.versionID != editor.activeVersionID)
                .accessibilityIdentifier("quickSubtitleDetails")
            }
            .padding(.leading, 8)
            TextField("字幕文字", text: $quickText, axis: .vertical)
                .font(.system(size: subtitles.style.fontSize + 3, weight: .semibold))
                .lineLimit(1...8).focused($quickFocus, equals: .original)
                .id(QuickSubtitleField.original)
                .accessibilityIdentifier("quickSubtitleText")
                .padding(.horizontal, 8)
                .background(SubtitleKeyboardMarker(part: .original, avoidance: inlineKeyboard))
            TextField("译文（可留空）", text: $quickTranslation, axis: .vertical)
                .font(.system(size: subtitles.style.fontSize)).lineLimit(1...6)
                .focused($quickFocus, equals: .translation)
                .id(QuickSubtitleField.translation)
                .accessibilityIdentifier("quickSubtitleTranslation")
                .padding(.horizontal, 8)
                .background(SubtitleKeyboardMarker(part: .translation, avoidance: inlineKeyboard))
            if let quickDraftError {
                Text(quickDraftError)
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("quickSubtitleDraftError")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    quickCancelButton
                    Spacer(minLength: 8)
                    quickSaveButton(for: target)
                    if hasFollowingCue(after: target) { quickSaveAndNextButton(for: target) }
                }
                VStack(spacing: 8) {
                    HStack {
                        quickCancelButton
                        Spacer()
                        quickSaveButton(for: target)
                    }
                    if hasFollowingCue(after: target) {
                        quickSaveAndNextButton(for: target).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .font(.subheadline)
            .padding(.leading, 8)
            .background(SubtitleKeyboardMarker(part: .actions, avoidance: inlineKeyboard))
        }
        .padding(16)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(SubtitleKeyboardMarker(part: .form, avoidance: inlineKeyboard))
        .task(id: target.id) {
            // 表单已装入后才请求第一响应者，不向尚不存在的 LazyVStack 文本框发送焦点。
            guard quickEditing?.id == target.id, quickFocus == nil else { return }
            quickFocus = .original
        }
    }

    private var quickCancelButton: some View {
        Button("取消") {
            let cleaned = finishQuickEdit()
            let feedback = L10n.text("已取消本次文字修改")
            editingFeedback = feedback
            if !cleaned { reportDraftCleanupFailure(after: feedback) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("cancelQuickSubtitle")
    }

    private func quickSaveButton(for target: EditingTarget) -> some View {
        Button("保存文字") { saveQuickEdit(target) }
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("saveQuickSubtitle")
            .disabled(target.trackID != trackID || !isCurrentTrack || target.versionID != editor.activeVersionID)
    }

    private func quickSaveAndNextButton(for target: EditingTarget) -> some View {
        Button("保存并下一句") { saveQuickEdit(target, advance: true) }
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("saveQuickSubtitleAndNext")
            .disabled(target.trackID != trackID || !isCurrentTrack || target.versionID != editor.activeVersionID)
    }

    private var readerControls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                PlayerSaveButtons(item: player.currentItem, favoriteWork: favoriteWork, onFavorite: onFavorite)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ReaderButtonStyle())
            .frame(maxWidth: .infinity, alignment: .leading)

            transportButtons
                .fixedSize(horizontal: true, vertical: false)
                .background(.ultraThinMaterial, in: Capsule())

            readerTools
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .foregroundStyle(.white.opacity(0.90))
        .tint(.white)
        .frame(maxWidth: 760)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private var transportButtons: some View {
        HStack(spacing: 0) {
            Button { player.previous() } label: { Label("上一首", systemImage: "backward.fill") }
                .disabled(quickEditing != nil)
            Button { player.togglePlayPause() } label: {
                Label(player.isPlaying ? L10n.text("暂停") : L10n.text("播放"), systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .foregroundStyle(Color(red: 0.18, green: 0.13, blue: 0.24))
                    .frame(width: 38, height: 38)
                    .background(Color(red: 0.87, green: 0.79, blue: 0.97), in: Circle())
            }
            .accessibilityIdentifier("readerPlayPause")
            Button { player.next() } label: { Label("下一首", systemImage: "forward.fill") }
                .disabled(quickEditing != nil)
        }
        .font(.body.weight(.semibold))
        .labelStyle(.iconOnly)
        .buttonStyle(ReaderButtonStyle())
    }

    private var readerTools: some View {
        HStack(spacing: 0) {
            if isEditing {
                Button { setEditing(false) } label: {
                    Label("退出编辑", systemImage: "xmark")
                }
                .accessibilityIdentifier("exitSubtitleEditing")
                .disabled(quickEditing != nil)
            }
            Menu { displayToggles } label: {
                Label("显示内容", systemImage: "character.bubble")
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("显示内容")
            subtitlesMenu
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ReaderButtonStyle())
    }

    private var subtitlesMenu: some View {
        Menu {
            Toggle("跟随播放位置", isOn: $followPlayback).disabled(!subtitles.hasTimedCues)
            if subtitles.isUntimed {
                Button("从头阅读", systemImage: "arrow.up.to.line") { readFromBeginning() }
                    .accessibilityIdentifier("readScriptFromBeginning")
            }
            Menu { displayToggles; styleButton } label: { Label("字幕样式", systemImage: "textformat.size") }
            Divider()
            Button("字幕浮窗", systemImage: "pip") { pictureInPicture.isSubtitleSheetPresented = true }
                .accessibilityIdentifier("subtitlePiPEntry")
            if !isSavedClip {
                Menu { editButton; versionsButton; importButton; clearButton } label: { Label("字幕", systemImage: "text.bubble") }
            }
            Divider()
            exportMenu
            shareButton


        } label: {
            Label("字幕工具", systemImage: "ellipsis")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(quickEditing != nil)
        .accessibilityIdentifier("subtitleTools")
    }

    private func selectSubtitleSource(_ source: SubtitleTrackRecord) -> String? {
        guard isCurrentTrack, let repository = store.subtitleRepository else { return L10n.text("当前曲目已切换。") }
        do {
            try repository.activateTrack(trackID: trackID, subtitleTrackID: source.id)
            editingFeedback = nil
            subtitles.forceReload()
            editor.load(trackID: trackID)
            refreshSubtitleSources()
            return nil
        } catch { return error.localizedDescription }
    }

    private func refreshSubtitleSources() {
        subtitleSources = (try? store.subtitleRepository?.tracks(forTrackID: trackID)) ?? []
    }

    private func readFromBeginning() {
        guard isCurrentPlayback else { return }
        readingResetToken = UUID()
    }

    @ViewBuilder
    private var displayToggles: some View {
        Toggle("显示原文", isOn: Binding(
            get: { subtitles.style.showOriginal },
            set: { subtitles.style.showOriginal = $0 }
        ))
        Toggle("显示译文", isOn: Binding(
            get: { subtitles.style.showTranslation },
            set: { subtitles.style.showTranslation = $0 }
        ))
    }

    private var styleButton: some View {
        Button { showStylePanel = true } label: {
            Label("字号与样式…", systemImage: "textformat.size")
        }
        .accessibilityIdentifier("subtitleStyleEntry")
    }

    private var editButton: some View {
        Button { setEditing(!isEditing) } label: {
            Label(isEditing ? L10n.text("退出编辑") : L10n.text("编辑字幕与时间轴"), systemImage: "pencil")
        }
        .accessibilityIdentifier("editSubtitles")
    }

    private func setEditing(_ editing: Bool) {
        editingFeedback = nil
        if !editing {
            // 在状态改变、编辑列表离场前保存最终位置；下次入场必须接收普通阅读页的新 session。
            recordEditingReadingPosition()
            editReadingSession?.flush()
            editReadingSession = nil
            editReadingReady = false
        }
        isEditing = editing
    }

    private var versionsButton: some View {
        Button { showVersions = true } label: {
            Label("字幕版本", systemImage: "clock.arrow.circlepath")
        }
        .accessibilityIdentifier("subtitleVersions")
    }

    private var exportMenu: some View {
        let timedCount = exportableCues.filter(\.hasTiming).count
        let isPartial = timedCount < exportableCues.count
        return Menu {
            Button("完整台本 TXT") { beginExport(format: nil) }
                .accessibilityIdentifier("export-txt").disabled(exportableCues.isEmpty)
            ForEach([SubtitleFormat.srt, .vtt, .ass], id: \.self) { format in
                let name = format.rawValue.uppercased()
                Button(isPartial ? L10n.text("\(name)（仅 \(timedCount)/\(exportableCues.count) 句有时间）") : name) {
                    beginExport(format: format)
                }
                .accessibilityIdentifier("export-\(format.rawValue)").disabled(timedCount == 0)
            }
        } label: {
            Label("导出字幕", systemImage: "square.and.arrow.up")
        }
    }

    private func beginExport(format: SubtitleFormat?) {
        guard isCurrentPlayback, let item = player.currentItem else { return }
        let name = item.isNetworkAudio ? item.trackTitle
            : URL(fileURLWithPath: item.filePath).deletingPathExtension().lastPathComponent
        // SubtitleEditorController applies SubtitleExporter.sanitizeFileName;
        // a network reference has no local file path to derive a name from.
        do {
            let url: URL
            if isSavedClip { url = try exportClipSubtitles(format: format, name: item.trackTitle) }
            else if let format { url = try editor.exportTimedFile(format: format, baseName: name) }
            else { url = try editor.exportTextFile(baseName: name) }
            exportURL = url
            exportRequest = SubtitleExportRequest(url: url)
        } catch {
            importMessage = L10n.text("导出失败：\(error.localizedDescription)")
        }
    }

    @State private var showClearConfirm = false

    /// Saved clips own an immutable subtitle snapshot; exporting never edits the source track.
    private func exportClipSubtitles(format: SubtitleFormat?, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleExports/SavedClips", isDirectory: true)
            .appendingPathComponent(String(-trackID), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content: String
        if let format {
            content = SubtitleExporter.export(subtitles.cues.filter(\.hasTiming), format: format)
        } else {
            content = subtitles.cues.map { cue in
                (cue.speaker.map { "\($0)：" } ?? "") + cue.displayText
            }.joined(separator: "\n\n")
        }
        let url = directory.appendingPathComponent(SubtitleExporter.sanitizeFileName(name))
            .appendingPathExtension(format?.fileExtension ?? "txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var importButton: some View {
        Button {
            showSubtitleImporter = true
        } label: {
            Label("导入字幕文件", systemImage: "square.and.arrow.down")
        }
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            showClearConfirm = true
        } label: {
            Label("清除这个曲目的字幕", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = exportURL {
            ShareLink(item: url) {
                Label("分享导出的字幕", systemImage: "doc.badge.arrow.up")
            }
        }
    }

    // MARK: - 弹窗

    private var versionSheet: some View {
        SubtitleVersionSheet(editor: editor, sources: subtitleSources, onSelectSource: selectSubtitleSource) {
            editingFeedback = nil
            subtitles.forceReload()
            refreshSubtitleSources()
        }
    }

    @ViewBuilder
    private func editSheet(for target: EditingTarget) -> some View {
        if isCurrentTrack, target.trackID == trackID, editor.activeVersionID == target.versionID {
            SubtitleEditSheet(
                index: target.index, cue: target.draft, durationMS: player.durationMS,
                playheadMS: player.positionMS,
                automaticEndFor: { start in
                    CueEditor.automaticEndMS(in: editor.cues, at: target.inserting ? nil : target.index,
                                             startMS: start, durationMS: player.durationMS)
                },
                onSave: { text, translation, start, end in
                    saveEditTarget(target, text: text, translation: translation, start: start, end: end)
                },
                onSaveAndNext: saveAndNextAction(for: target),
                onDelete: target.inserting ? nil : {
                    guard isCurrentTrack, target.trackID == trackID, editor.activeVersionID == target.versionID else { return L10n.text("当前台词已切换。") }
                    editor.deleteCue(at: target.index)
                    return saveCueChanges(note: "删除一句")
                },
                onPlayFromHere: { start in
                    guard isCurrentTrack else { return L10n.text("曲目已切换，请回到原曲试听。") }
                    player.seek(to: start)
                    player.resume()
                    return player.isPlaying ? nil : (player.errorMessage ?? L10n.text("未能开始播放。"))
                }
            )
            // Advance within the same presented sheet, but recreate the row's
            // local form state so text, timing, errors and audition state do not leak.
            .id(target.draft.id)
        } else {
            ContentUnavailableView("当前台词已切换", systemImage: "text.bubble")
        }
    }

    private func saveEditTarget(_ target: EditingTarget, text: String, translation: String?,
                                start: Int?, end: Int?) -> String? {
        guard isCurrentTrack, target.trackID == trackID, editor.activeVersionID == target.versionID else {
            return L10n.text("当前台词已切换。")
        }
        guard editor.applyEdit(at: target.index, inserting: target.inserting, text: text,
                               translation: translation, startMS: start, endMS: end,
                               durationMS: player.durationMS) else {
            return L10n.text("所选时间超出有效范围，请重新选择。")
        }
        return saveCueChanges(note: target.inserting ? "增加一句" : "手工修正")
    }

    private func saveAndNextAction(for target: EditingTarget) -> SubtitleEditSheet.SaveAction? {
        let nextIndex = target.index + 1
        guard hasFollowingCue(after: target) else { return nil }
        return { text, translation, start, end in
            // Revalidate the original version before saving. A second tap or a
            // source/track change must never save this form into another row.
            guard hasFollowingCue(after: target) else { return L10n.text("下一句已变更，请重新打开编辑。") }
            if let error = saveEditTarget(target, text: text, translation: translation, start: start, end: end) {
                return error
            }
            guard let versionID = editor.activeVersionID, editor.cues.indices.contains(nextIndex) else {
                return L10n.text("本句已保存，请返回台本重新选择下一句。")
            }
            var next = EditingTarget(trackID: target.trackID, index: nextIndex, versionID: versionID,
                                     inserting: false, draft: editor.cues[nextIndex])
            next.id = target.id
            editingTarget = next
            return nil
        }
    }

    private func hasFollowingCue(after target: EditingTarget) -> Bool {
        if target.inserting {
            // Before committing an inserted row, the following original row is
            // still at its insertion index. It shifts right only after saving.
            return target.index > 0 && editor.cues.indices.contains(target.index - 1)
                && editor.cues.indices.contains(target.index)
        }
        return editor.cues.indices.contains(target.index) && editor.cues.indices.contains(target.index + 1)
    }

    private func saveCueChanges(note: String, resolveAutomaticEnds: Bool = true) -> String? {
        guard editor.saveAsNewVersion(note: note, durationMS: player.durationMS, resolveAutomaticEnds: resolveAutomaticEnds) else {
            let error = editor.message ?? L10n.text("字幕保存失败，请重试。")
            editor.load(trackID: trackID)
            return error
        }
        publishSavedEditorCues()
        editingFeedback = editor.message ?? L10n.text("字幕已保存为新版本")
        return nil
    }

    private func publishSavedEditorCues() {
        if let source = editor.subtitleTrackID,
           subtitles.applySavedEditorCues(editor.cues, trackID: trackID, subtitleTrackID: source) {
            subtitles.update(positionMS: player.positionMS)
        } else { subtitles.forceReload() }
    }

    // MARK: - 逻辑

    private func beginQuickEdit(_ cue: SubtitleCue) {
        guard quickEditing == nil, isCurrentTrack, let versionID = editor.activeVersionID,
              editor.cues.indices.contains(cue.index), editor.cues[cue.index].text == cue.text else { return }
        editingFeedback = nil
        recordEditingReadingPosition()
        editReadingSession?.flush()
        followPlayback = false
        editResizeSession = nil
        quickFocus = nil
        let draft = editor.cues[cue.index]
        quickText = draft.text
        quickTranslation = draft.translatedText ?? ""
        quickEditing = EditingTarget(trackID: trackID, index: cue.index, versionID: versionID, inserting: false, draft: draft)
        persistQuickDraft()
    }

    /// 正式保存/明确取消与草稿清理分别报告；清理失败不能推翻已提交的字幕。
    private func finishQuickEdit() -> Bool {
        var cleaned = true
        if let target = quickEditing {
            do { try SubtitleQuickDraftStore().remove(for: target.trackID) }
            catch { cleaned = false }
            if target.trackID == trackID, editor.cues.indices.contains(target.index) {
                if !subtitles.hasTimedCues, let session = editReadingSession, session.sourceID == editor.subtitleTrackID {
                    session.record(cues: editor.cues, index: target.index, fraction: 0)
                    session.flush()
                }
            }
        }
        quickFocus = nil
        quickEditing = nil
        quickDraftError = nil
        return cleaned
    }

    private func reportDraftCleanupFailure(after feedback: String) {
        let message = feedback + "\n" + L10n.text("旧草稿未能清除，原有草稿数据已保留。")
        editingFeedback = message
        importMessage = message
    }

    private func persistQuickDraft() {
        guard let target = quickEditing else { return }
        do {
            try SubtitleQuickDraftStore().save(SubtitleQuickDraft(trackID: target.trackID, versionID: target.versionID,
                index: target.index, text: quickText, translation: quickTranslation))
            quickDraftError = nil
        } catch {
            // Keep the active text fields and focus; typing must not trigger a modal alert per keystroke.
            quickDraftError = L10n.text("文字草稿暂时无法保存，当前输入仍保留在这里。请先保存字幕，或复制文字后再离开。")
        }
    }

    private func saveQuickEdit(_ target: EditingTarget, advance: Bool = false) {
        guard quickEditing?.id == target.id, isCurrentTrack, target.trackID == trackID,
              editor.activeVersionID == target.versionID else {
            importMessage = L10n.text("当前台词已切换，文字草稿仍保留在这里。")
            return
        }
        if advance && !hasFollowingCue(after: target) {
            importMessage = L10n.text("下一句已变更，请重新打开编辑。")
            return
        }
        let translation = quickTranslation.isEmpty ? nil : quickTranslation
        if quickText == target.draft.text, translation == target.draft.translatedText {
            let feedback = L10n.text("文字未改动")
            editingFeedback = feedback
            if advance { advanceQuickEdit(after: target) }
            else if !finishQuickEdit() { reportDraftCleanupFailure(after: feedback) }
            return
        }
        guard editor.applyTextEdit(at: target.index, text: quickText, translation: translation) else { return }
        if let error = saveCueChanges(note: "修改台词文字", resolveAutomaticEnds: false) {
            importMessage = error
        } else if advance { advanceQuickEdit(after: target) }
        else if !finishQuickEdit() { reportDraftCleanupFailure(after: L10n.text("字幕已保存为新版本")) }
    }

    private func advanceQuickEdit(after target: EditingTarget) {
        let nextIndex = target.index + 1
        guard let versionID = editor.activeVersionID, editor.cues.indices.contains(nextIndex) else { return }
        let next = editor.cues[nextIndex]
        quickFocus = nil
        quickText = next.text
        quickTranslation = next.translatedText ?? ""
        quickEditing = EditingTarget(trackID: target.trackID, index: nextIndex, versionID: versionID,
                                     inserting: false, draft: next)
        // Replace this track's persisted draft only after a successful save (or
        // an unchanged row). Failed commits retain the previous row and text.
        persistQuickDraft()
    }

    private func insertBlankLine(after cue: SubtitleCue) {
        guard quickEditing == nil, isCurrentTrack, editor.cues.indices.contains(cue.index),
              editor.cues[cue.index].text == cue.text else { return }
        guard let index = editor.insertAndSaveBlankCue(after: cue.index) else {
            importMessage = editor.message ?? L10n.text("添加字幕失败，请重试。")
            return
        }
        publishSavedEditorCues()
        beginQuickEdit(editor.cues[index])
        editingFeedback = L10n.text("空行已添加；文字需点「保存文字」")
    }

    private func seekTo(_ cue: SubtitleCue) {
        guard isCurrentPlayback else { return }
        if isEditing {
            beginQuickEdit(cue)
            return
        }
        if !cue.hasTiming {
            openEditor(for: cue)
            return
        }
        player.seek(to: cue.startMS)
    }

    private func openEditor(for cue: SubtitleCue, insertingBelow: Bool = false) {
        // 未打轴台词可能都从 0 开始，使用同一字幕版本内的行号定位。
        guard quickEditing == nil, isCurrentTrack, let versionID = editor.activeVersionID,
              editor.cues.indices.contains(cue.index), editor.cues[cue.index].text == cue.text else { return }
        editingFeedback = nil
        editResizeSession = nil
        let index = insertingBelow ? cue.index + 1 : cue.index
        let draft = insertingBelow
            ? SubtitleCue(index: index, startMS: 0, endMS: 0, text: "", status: .untimed)
            : editor.cues[index]
        editingTarget = EditingTarget(trackID: trackID, index: index, versionID: versionID, inserting: insertingBelow, draft: draft)
    }

    private func attachEditor() {
        guard isCurrentTrack, let repository = store.subtitleRepository else { return }
        refreshSubtitleSources()
        editor.attach(repository: repository)
        editor.load(trackID: trackID)
        if quickEditing == nil, let saved = SubtitleQuickDraftStore().draft(for: trackID) {
            isEditing = true
            followPlayback = false
            quickText = saved.text
            quickTranslation = saved.translation
            let draft = editor.cues.indices.contains(saved.index) ? editor.cues[saved.index]
                : SubtitleCue(index: saved.index, startMS: 0, endMS: 0, text: "", status: .untimed)
            quickEditing = EditingTarget(trackID: saved.trackID, index: saved.index, versionID: saved.versionID,
                                         inserting: false, draft: draft)
        }
        #if DEBUG
        // 调试：自动跑一遍"改文字 → 存新版本 → 删除一句"，把结果写日志
        if CommandLine.arguments.contains("-editSelfTest") {
            runEditSelfTest()
        }
        // 调试：直接打开第一句的编辑面板
        if CommandLine.arguments.contains("-editSubtitle"), !editor.cues.isEmpty {
            isEditing = true
            openEditor(for: editor.cues[0])
        }
        if CommandLine.arguments.contains("-subtitleVersions") {
            showVersions = true
        }
        #endif
    }

    #if DEBUG
    /// 编辑功能自检：改文字、加一句、删一句、存版本，结果写到 Documents/edit-selftest.txt
    private func runEditSelfTest() {
        var lines: [String] = []
        lines.append("初始字幕数: \(editor.cues.count)")
        guard !editor.cues.isEmpty else {
            lines.append("没有字幕，跳过")
            writeSelfTest(lines)
            return
        }

        let original = editor.cues[0].text
        editor.setText(at: 0, to: original + "（已修改）")
        lines.append("改文字: \(editor.hasChanges ? "有改动" : "没改动")")

        let inserted = editor.insertCue(after: 0)
        lines.append("插入新句: \(inserted.map(String.init) ?? "失败")，现在 \(editor.cues.count) 句")

        let saved1 = editor.saveAsNewVersion(note: "自检-修改", durationMS: player.durationMS)
        lines.append("保存版本: \(saved1 ? "成功" : "失败")，版本数 \(editor.versions.count)")

        editor.deleteCue(at: 0)
        let saved2 = editor.saveAsNewVersion(note: "自检-删除", durationMS: player.durationMS)
        lines.append("删除后保存: \(saved2 ? "成功" : "失败")，剩 \(editor.cues.count) 句")

        lines.append("当前版本: v\(editor.versions.last?.versionNo ?? 0)")
        writeSelfTest(lines)
    }
    #endif

    /// 允许选择的文件类型。
    ///
    /// 这里故意用 `.item`（任意文件）：`.srt` 这类扩展名在系统里
    /// 往往没有对应的标准 UTType，一旦按类型过滤，文件在选择器里
    /// 会变成灰色不可选，表现就是"点了没反应、导不进来"。
    /// 反正导入后会按内容嗅探，选错文件也只会给出明确报错。
    private var subtitleTypes: [UTType] {
        [.item]
    }

    /// 导入用户选的字幕文件（Mac 生成后 AirDrop 过来的那种）
    private func handleSubtitleImport(_ result: Result<[URL], Error>) {
        // Dismissing Files is not an import attempt, even if playback moved to
        // another track while the browser was open.
        if case .failure(let error) = result, (error as? CocoaError)?.code == .userCancelled { return }
        guard let repository = store.subtitleRepository else {
            importMessage = L10n.text("字幕存储未就绪")
            return
        }
        guard isCurrentTrack else {
            importMessage = L10n.text("当前曲目已切换，请重新选择字幕")
            return
        }

        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            importMessage = L10n.text("选择文件失败：\(error.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url),
                  let text = SubtitleTextDecoder.decode(data: data) else {
                importMessage = L10n.text("读不出这个文件")
                return
            }
            let ext = url.pathExtension
            let result = SubtitleParser.parse(text, formatHint: SubtitleFormat.from(fileExtension: ext))
            guard !result.cues.isEmpty else {
                importMessage = L10n.text("这个文件里没有解析出字幕")
                return
            }

            do {
                _ = try repository.createTrack(
                    trackID: trackID,
                    kind: .manual,
                    language: ext.contains("zh") ? "zh" : nil,
                    label: url.lastPathComponent,
                    cues: result.cues,
                    note: "手动导入",
                    activate: true
                )
                subtitles.forceReload()
                editor.load(trackID: trackID)
                refreshSubtitleSources()
                subtitleReceipt = SubtitleImportReceipt(detail: L10n.text("\(result.cues.count) 句字幕"))
            } catch {
                importMessage = L10n.text("保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func writeSelfTest(_ lines: [String]) {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }
        try? lines.joined(separator: "\n")
            .write(to: documents.appendingPathComponent("edit-selftest.txt"),
                   atomically: true, encoding: .utf8)
    }
}

/// 一轮分区拖动固定留白与阅读锚点，直到松手后的定位结束。
struct SubtitleResizeSession {
    let id = UUID()
    let position: SubtitleRowAnchor.ReadingPosition?
    let focus: SubtitleScrollFocus
}

/// 滚动视窗只占全屏的一部分。首尾留出足够空间后，长短不同的台词都可对准同一条中线。
struct SubtitleScrollFocus: Equatable {
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let targetY: CGFloat

    init(pageMidY: CGFloat, viewport: CGRect, viewportFocusFraction: CGFloat = 0) {
        let height = max(0, viewport.height)
        let edge = min(28, height / 2)
        let requested = pageMidY + (viewport.midY - pageMidY) * min(1, max(0, viewportFocusFraction))
        topPadding = min(max(edge, requested - viewport.minY), height - edge)
        bottomPadding = height - topPadding
        targetY = viewport.minY + topPadding
    }

    func anchor(rowHeight: CGFloat) -> UnitPoint {
        let travel = topPadding + bottomPadding - rowHeight
        guard abs(travel) > 1 else { return .center }
        // scrollTo 同时对齐行和视窗上的同一比例；扣掉半行，落在中线的才是行中心。
        let fraction = (topPadding - rowHeight / 2) / travel
        return UnitPoint(x: 0.5, y: min(1, max(0, fraction)))
    }
}

private struct EditRowSize: Equatable {
    let id: UUID
    let height: CGFloat
}

private struct EditRowSizeKey: PreferenceKey {
    static var defaultValue: EditRowSize? { nil }
    static func reduce(value: inout EditRowSize?, nextValue: () -> EditRowSize?) {
        if let next = nextValue() { value = next }
    }
}

private struct SubtitleExportRequest: Identifiable {
    let url: URL
    var id: URL { url }
}

/// 保存一份副本，分享菜单仍可使用原来的临时文件。
private struct SubtitleFileDestination: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onClose() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onClose() }
    }
}

private struct EditingTarget: Identifiable {
    var id = UUID()
    let trackID: Int64
    let index: Int
    let versionID: Int64
    let inserting: Bool
    let draft: SubtitleCue
}

private enum QuickSubtitleField: Hashable {
    case original, translation
}

/// The hide timer changes only this leaf view, so an open system Menu is not
/// rebuilt by a page-level state update at the end of its three-second interval.
private struct SubtitleDividerHandle: View {
    let landscape: Bool
    let activity: UUID
    let resizing: Bool
    @State private var visible = true

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.75))
            .frame(width: landscape ? 4 : 44, height: landscape ? 60 : 4)
            .shadow(color: .black.opacity(0.4), radius: 3)
            .opacity(visible || resizing ? 1 : 0)
            .animation(visible ? nil : .easeOut(duration: 0.35), value: visible)
            .task(id: activity) {
                visible = true
                guard !resizing else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !Task.isCancelled, !resizing else { return }
                visible = false
            }
    }
}

private struct ReaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct SubtitleCueRow: View {
    let cue: SubtitleCue
    let isCurrent: Bool
    let distance: Int
    let editing: Bool
    let style: SubtitleStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if editing {
                Text(cue.hasTiming ? SubtitleTime.clock(cue.startMS) : L10n.text("未打轴")).font(.caption.monospacedDigit())
            }
            if style.showOriginal || editing {
                Text(editing && cue.isEmpty ? L10n.text("空白字幕，点按输入") : cue.text)
                    .font(.system(size: style.fontSize + 3, weight: isCurrent ? .bold : .semibold))
            }
            if style.showTranslation, let translated = cue.translatedText, !translated.isEmpty {
                Text(translated).font(.system(size: style.fontSize, weight: isCurrent ? .semibold : .regular))
            }
        }
        .foregroundStyle(.white.opacity(isCurrent || editing ? 1 : (distance < 2 ? 0.77 : 0.56)))
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, editing ? 2 : 11)
        .contentShape(Rectangle())
    }
}

/// 字幕样式设置
struct SubtitleStyleSheet: View {
    let mode: SubtitleStyleMode
    @EnvironmentObject private var subtitles: SubtitleController
    @Environment(\.dismiss) private var dismiss

    private var style: SubtitleStyle { subtitles.style(for: mode) }
    private var title: String { mode == .call ? L10n.text("通话字幕样式") : L10n.text("全屏字幕样式") }
    private var scope: String {
        mode == .call
            ? L10n.text("自动保存，适用于所有作品的通话模式。")
            : L10n.text("自动保存，适用于所有作品的全屏字幕与普通播放。")
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<SubtitleStyle, Value>) -> Binding<Value> {
        Binding(get: { subtitles.style(for: mode)[keyPath: keyPath] }, set: { value in
            var updated = subtitles.style(for: mode)
            updated[keyPath: keyPath] = value
            subtitles.setStyle(updated, for: mode)
        })
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section("字号") {
                    HStack {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(
                            value: binding(\.fontSize),
                            in: 12...30,
                            step: 1
                        )
                        .accessibilityIdentifier("subtitleStyleFontSize")
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int(style.fontSize))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 24, alignment: .trailing)
                            .accessibilityIdentifier("subtitleStyleFontSizeValue")
                    }
                }

                Section("显示内容") {
                    Toggle("显示原文", isOn: binding(\.showOriginal))
                        .accessibilityIdentifier("subtitleStyleOriginal")
                    Toggle("显示译文", isOn: binding(\.showTranslation))
                        .accessibilityIdentifier("subtitleStyleTranslation")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("预览").font(.caption2).foregroundStyle(.secondary)
                        if style.showOriginal {
                            Text("あ、そこはだめ")
                                .font(.system(size: style.fontSize, weight: .medium))
                        }
                        if style.showTranslation {
                            Text("啊，那里不行")
                                .font(.system(size: style.fontSize - 3))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                Section {
                    Text(scope)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subtitleStyleScope")
                    Text("字幕文件放在音频同目录、文件名相同即可自动加载。日文原文 + 中文译文两个文件会自动配对。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .appNavigationColors().navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("subtitleStyleDone")
                }
            }
        }
        // Settings follow the selected skin even when presented by the dark reader.
        .appSettingsColorScheme()
    }
}
