import SwiftUI

/// 全屏播放器。横屏使用封面、控制两列，竖屏保留单列。
struct PlayerView: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var scrubPosition: Int?

    @EnvironmentObject private var subtitles: SubtitleController
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var pictureInPicture: AppPictureInPictureCoordinator

    @State private var showSubtitlePage = false
    @State private var subtitleClipDraft: SubtitleClipDraft?
    @State private var subtitleClipSavedToken = UUID()

    @State private var captureClipDraft: SubtitleClipDraft?
    @State private var captureSavedToken = UUID()
    @State private var artworkWork: WorkRecord?
    @State private var favoriteWork: WorkRecord?
    @State private var favoriteTarget: WorkRecord?
    @State private var showQueue = false
    @State private var showSleepTimer = false
    @State private var readerFavoriteTarget: WorkRecord?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if proxy.size.width >= 800 || (proxy.size.width > proxy.size.height && proxy.size.width >= 560) {
                    landscapePlayer(in: proxy.size)
                } else {
                    ScrollView {
                        PortraitPlayerLayout(minimumHeight: max(0, proxy.size.height - 16)) {
                            titleSection.offset(y: -4)
                            artwork(maxHeight: min(400, proxy.size.height * 0.38))
                                .padding(.horizontal, 12)
                                .offset(y: -8)
                            if offersSubtitles { compactSubtitle.offset(y: -8) }
                            else { Color.clear.frame(height: 0) }
                            playbackPanel
                        }
                        .frame(maxWidth: 660)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .accessibilityHidden(showSubtitlePage)
            .background {
                if AppTheme.isPurple {
                    AppTheme.purplePlayerBackdrop.ignoresSafeArea()
                } else {
                    AppTheme.painted(Color(uiColor: .secondarySystemGroupedBackground), AppTheme.background).ignoresSafeArea()
                }
            }
            .toolbarBackground(AppTheme.isPurple ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Label("收起播放器", systemImage: "chevron.down").playerToolbarTarget()
                    }
                        .accessibilityIdentifier("collapsePlayer")
                        .playerToolbarCapsule()
                }
                .playerToolbarMaterial()
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: AppTheme.isPurple ? 0 : nil) {
                        if player.currentItem?.isSavedClip == false {
                            Button { player.beginCall() } label: {
                                Label("模拟通话", systemImage: "phone").playerToolbarTarget()
                            }
                            .accessibilityIdentifier("startCall")
                        }
                        if offersSubtitles {
                            Button { showSubtitlePage = true } label: {
                                Label("全屏字幕", systemImage: "arrow.up.left.and.arrow.down.right")
                                    .playerToolbarTarget()
                            }
                            .accessibilityIdentifier("expandSubtitles")
                        }
                    }
                    .playerToolbarCapsule()
                }
                .playerToolbarMaterial()
            }
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: player.currentItem?.id, initial: true) { _, _ in
                refreshWork()
            }
            .onChange(of: store.contentRevision) { _, _ in
                refreshWork()
            }
            .onChange(of: player.currentItem, initial: true) { _, item in
                guard let item, !item.isVideo else {
                    readerFavoriteTarget = nil
                    if subtitleClipDraft == nil { showSubtitlePage = false }
                    subtitles.clear()
                    return
                }
                subtitles.load(item: item, store: store)
                subtitles.update(positionMS: player.positionMS)
                if item.isSavedClip, subtitles.cues.isEmpty, subtitleClipDraft == nil {
                    showSubtitlePage = false
                }
            }
            // The root PiP coordinator updates subtitle time once, including when this page is absent.
            .onAppear {
                #if DEBUG
                let debugSubtitlePage = CommandLine.arguments.contains("-subtitlePage")
                #else
                let debugSubtitlePage = false
                #endif
                if offersSubtitles, debugSubtitlePage || pictureInPicture.wantsSubtitlePage {
                    showSubtitlePage = true
                }
            }
            .onChange(of: pictureInPicture.wantsSubtitlePage) { _, requested in
                if requested, offersSubtitles { showSubtitlePage = true }
            }
            .sheet(item: $captureClipDraft) { draft in
                SubtitleClipSheet(draft: draft) {
                    if player.currentItem?.id == draft.item.id {
                        player.clearClipStart()
                        captureSavedToken = UUID()
                    }
                }
            }
            .sheet(item: $favoriteTarget) { work in
                WorkFavoritePicker(workID: work.id)
            }
            .sheet(isPresented: $showQueue) { PlaybackQueueSheet() }
            .sheet(isPresented: $showSleepTimer) { SleepTimerSheet() }
            .fullScreenCover(isPresented: $showSubtitlePage) {
                ZStack {
                    if let item = player.currentItem, offersSubtitles {
                        SubtitlePageView(coverPath: artworkWork?.resolvedCoverPath, trackID: item.trackID,
                                         favoriteWork: favoriteWork,
                                         onFavorite: { readerFavoriteTarget = $0 },
                                         clipSavedToken: subtitleClipSavedToken,
                                         onClipRequest: { subtitleClipDraft = $0 })
                            .id(item.id)
                    }
                }
                .sheet(item: $subtitleClipDraft) { draft in
                    SubtitleClipSheet(draft: draft) {
                        if player.currentItem?.id == draft.item.id { subtitleClipSavedToken = UUID() }
                    }
                }
                .sheet(item: $readerFavoriteTarget) { work in
                    WorkFavoritePicker(workID: work.id)
                }
                .onChange(of: subtitleClipDraft == nil) { _, empty in
                    if empty && !offersSubtitles { showSubtitlePage = false }
                }
                .playlistAdditionFeedback()
            }
        }
    }

    private func refreshWork() {
        guard let item = player.currentItem else {
            artworkWork = nil
            favoriteWork = nil
            return
        }
        let work = try? store.work(id: item.workID)
        artworkWork = work
        if item.isSavedClip {
            // 合并音频的封面可能取自第一部作品；只有原音轨仍存在的摘选才有明确的作品。
            let entry = store.playlistEntries.first { $0.id == -item.trackID }
            favoriteWork = entry?.trackID != nil && entry?.isMerged == false ? work : nil
        } else {
            favoriteWork = work
        }
    }

    private var offersSubtitles: Bool {
        guard let item = player.currentItem, !item.isVideo else { return false }
        return !item.isSavedClip || (subtitles.loadedTrackID == item.trackID && !subtitles.cues.isEmpty)
    }

    private func landscapePlayer(in size: CGSize) -> some View {
        let inset: CGFloat = size.width < 740 ? 10 : 18
        let gap: CGFloat = size.width < 740 ? 20 : 32
        let width = min(1080, size.width - inset * 2)
        let coverWidth = min(width * 0.39, size.height * 1.14)

        return ScrollView {
            HStack(spacing: gap) {
                VStack(spacing: 10) {
                    artwork(maxHeight: min(size.height * 0.62, 380))
                    titleSection
                }
                .frame(width: coverWidth)

                VStack(spacing: size.height < 340 ? 4 : 8) {
                    if offersSubtitles { compactSubtitle }
                    progressSection(horizontalInset: 4)
                    transportControls(playSize: 50)
                    captureControls
                    optionButtons
                    playbackError
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
            .frame(width: width)
            .frame(maxWidth: .infinity, minHeight: size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func artwork(maxHeight: CGFloat) -> some View {
        // Scale the artwork inside its layout slot and keep the displayed radius at 14 pt.
        let scale: CGFloat = 0.97
        return CoverImageView(path: artworkWork?.resolvedCoverPath, cornerRadius: 14 / scale,
                              maxPixels: 1600, showsOriginal: true, playerCoverMode: artworkWork?.playerCoverMode ?? .original)
            .scaleEffect(scale, anchor: .center)
            .frame(maxWidth: 500, maxHeight: maxHeight)
            .shadow(color: AppTheme.shadow.opacity(0.18), radius: 8, y: 4)
    }

    private var compactSubtitle: some View {
        Button { showSubtitlePage = true } label: {
            VStack(spacing: 3) {
                if let cue = subtitles.currentCue {
                    if subtitles.style.showOriginal {
                        Text(cue.text)
                            .font(.system(size: subtitles.style.fontSize, weight: .semibold))
                    }
                    if subtitles.style.showTranslation, let translation = cue.translatedText, !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: subtitles.style.fontSize - 2))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                } else if let upcoming = subtitles.upcomingCue, subtitles.style.showOriginal {
                    Text(upcoming.text).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                } else if subtitles.cues.contains(where: { !$0.hasTiming }) {
                    Text("查看台本 · 尚未打轴").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                } else if subtitles.cues.isEmpty {
                    Text("添加字幕").font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
            }
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var titleSection: some View {
        VStack(spacing: 3) {
            Text(player.currentItem?.trackTitle ?? L10n.text("未在播放"))
                .font(.headline)
                .lineLimit(2)
            if player.currentItem != nil {
                Text(player.currentWorkTitle).font(.subheadline).foregroundStyle(AppTheme.secondaryText).lineLimit(1)
            }
            if player.hasQueue { Text(player.queuePositionText).font(.caption2).foregroundStyle(AppTheme.secondaryText) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var playbackPanel: some View {
        VStack(spacing: 0) {
            captureControls.offset(y: -8)
            progressSection(horizontalInset: 24)
                .padding(.top, 4)
                .offset(y: -16)
            transportControls(playSize: 64)
                .padding(.top, 4)
                .offset(y: -16)
            optionButtons.padding(.vertical, 8).padding(.top, 16)
            if player.errorMessage != nil { playbackError.padding(.top, 10) }
        }
    }

    private var captureControls: some View {
        PlaylistCaptureControls(savedToken: captureSavedToken) { draft in captureClipDraft = draft }
    }

    private var optionButtons: some View {
        PlayerOptionsRow(favoriteWork: favoriteWork,
                         onFavorite: { favoriteTarget = $0 }, onQueue: { showQueue = true },
                         onSleep: { showSleepTimer = true }, labelInk: AppTheme.isPurple ? .white : nil)
    }

    @ViewBuilder private var playbackError: some View {
        if let error = player.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func progressSection(horizontalInset: CGFloat) -> some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { Double(scrubPosition ?? player.positionMS) },
                    set: { scrubPosition = Int($0.rounded()) }
                ),
                in: 0...Double(max(1, player.durationMS)),
                onEditingChanged: { dragging in
                    if dragging {
                        if scrubPosition == nil { scrubPosition = player.positionMS }
                    } else if let target = scrubPosition {
                        player.seek(to: target)
                        scrubPosition = nil
                    }
                }
            )
            .frame(minHeight: 44)
            .tint(AppTheme.isPurple ? AppTheme.purplePlaybackIndicator : AppTheme.optionalTint)
            .accessibilityIdentifier("playbackSeek")
            .accessibilityLabel("播放进度")
            .accessibilityValue(SubtitleTime.clock(scrubPosition ?? player.positionMS))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: player.seek(to: player.positionMS + 5_000)
                case .decrement: player.seek(to: player.positionMS - 5_000)
                @unknown default: break
                }
            }
            .id(player.currentItem?.id)
            .onChange(of: player.currentItem?.id) { scrubPosition = nil }
            .disabled(player.durationMS <= 0)
            .padding(.horizontal, horizontalInset)

            HStack {
                Text(SubtitleTime.clock(scrubPosition ?? player.positionMS))
                Spacer()
                Text(SubtitleTime.clock(player.durationMS))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.secondaryText)
            .padding(.horizontal, horizontalInset + 4)
        }
    }


    private func transportControls(playSize: CGFloat) -> some View {
        HStack(spacing: 36) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 24)).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("上一首")

            Button {
                player.togglePlayPause()
            } label: {
                let symbol = Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: playSize))
                if AppTheme.isPurple {
                    symbol.symbolRenderingMode(.palette)
                        .foregroundStyle(AppTheme.iconTint, AppTheme.purplePlayerButton)
                } else {
                    symbol
                }
            }
            .accessibilityLabel(player.isPlaying ? L10n.text("暂停") : L10n.text("播放"))
            .accessibilityIdentifier("playerPlayPause")

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 24)).frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("下一首")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

private extension View {
    @ViewBuilder func playerToolbarTarget() -> some View {
        labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }

    @ViewBuilder func playerToolbarCapsule() -> some View {
        if AppTheme.isPurple {
            buttonStyle(.plain)
                .foregroundStyle(AppTheme.iconTint)
                .background(AppTheme.purplePlayerButton, in: Capsule())
        } else {
            self
        }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder func playerToolbarMaterial() -> some ToolbarContent {
        if #available(iOS 26, *), AppTheme.isPurple {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Keep both text blocks centered in the space they describe: the title above
/// the artwork, and the compact subtitle between the artwork and clip marker.
/// Short screens and large text grow the scroll content instead of overlapping.
private struct PortraitPlayerLayout: Layout {
    let minimumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 388
        let heights = measuredHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: max(minimumHeight, heights.reduce(0, +) + 24))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let heights = measuredHeights(width: bounds.width, subviews: subviews)
        let breathingRoom = max(0, bounds.height - heights.reduce(0, +)) / 2
        let titleRegion = heights[0] + breathingRoom
        let subtitleRegion = heights[2] + breathingRoom
        let positions = [
            (titleRegion - heights[0]) / 2,
            titleRegion,
            titleRegion + heights[1] + (subtitleRegion - heights[2]) / 2,
            titleRegion + heights[1] + subtitleRegion,
        ]
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY + positions[index]),
                anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: heights[index]))
        }
    }

    private func measuredHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        subviews.map { view in
            let height = view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            return height.isFinite ? max(0, height) : 0
        }
    }
}

struct PlayerOptionsRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var player: PlayerController
    let favoriteWork: WorkRecord?
    let onFavorite: (WorkRecord) -> Void
    let onQueue: () -> Void
    var onSleep: (() -> Void)? = nil
    var onSubtitleStyle: (() -> Void)? = nil
    var callSubtitleInMiddle = false
    var onCallSubtitlePosition: (() -> Void)?
    var callSpatialEnabled = false
    var callSpatialAvailable = false
    var onCallSpatialToggle: (() -> Void)?
    var labelInk: Color? = nil

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 3), spacing: 12) {
            if let onCallSpatialToggle {
                Button(action: onCallSpatialToggle) {
                    Label("空间效果", systemImage: callSpatialEnabled ? "square.3.layers.3d.down.right" : "square.3.layers.3d")
                }
                .foregroundStyle(callSpatialEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .disabled(!callSpatialAvailable)
                .accessibilityLabel("空间效果")
                .accessibilityValue(callSpatialEnabled ? L10n.text("已开启") : L10n.text("已关闭"))
                .accessibilityIdentifier("callSpatialToggle")
            } else {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { value in
                        Button { player.rate = value } label: {
                            if abs(player.rate - value) < 0.01 {
                                Label(rateLabel(value), systemImage: "checkmark")
                            } else {
                                Text(rateLabel(value))
                            }
                        }
                    }
                } label: {
                    Label(rateLabel(player.rate), systemImage: "speedometer")
                }
                .accessibilityLabel("播放速度")
                .accessibilityValue(rateLabel(player.rate))
                .accessibilityIdentifier("playbackSpeed")
            }

            AddTrackToPlaylistButton(item: player.currentItem)

            if let onSubtitleStyle {
                Button(action: onSubtitleStyle) {
                    Label("字幕样式", systemImage: "textformat.size")
                }
                .accessibilityLabel("字幕大小与样式")
                .accessibilityIdentifier("callSubtitleStyle")
            } else if let onSleep {
                Button(action: onSleep) {
                    Label(player.sleepTimer == .off ? L10n.text("定时") : L10n.text("定时中"),
                          systemImage: player.sleepTimer == .off ? "moon" : "moon.fill")
                }
                .foregroundStyle(player.sleepTimer == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .disabled(player.currentItem == nil)
                .accessibilityLabel("睡眠定时")
                .accessibilityValue(player.sleepTimer == .off ? L10n.text("已关闭") : L10n.text("已开启"))
                .accessibilityIdentifier("playerSleepTimer")
            }

            repeatOrSubtitlePositionButton
            PlayerFavoriteButton(favoriteWork: favoriteWork, onFavorite: onFavorite)

            Button(action: onQueue) {
                Label("队列", systemImage: "list.bullet")
            }
            .accessibilityLabel("当前播放队列")
            .accessibilityIdentifier("showPlaybackQueue")
            .disabled(!player.hasQueue)
        }
        .labelStyle(PlayerOptionLabelStyle(ink: labelInk))
        .buttonStyle(.plain)
    }

    private func rateLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    @ViewBuilder
    private var repeatOrSubtitlePositionButton: some View {
        if player.isInCall, let onCallSubtitlePosition {
            Button(action: onCallSubtitlePosition) {
                Label("字幕位置", systemImage: callSubtitleInMiddle ? "arrow.down" : "arrow.up")
            }
            .accessibilityLabel(callSubtitleInMiddle ? L10n.text("字幕移到底部") : L10n.text("字幕移到中间"))
            .accessibilityValue(callSubtitleInMiddle ? L10n.text("中间") : L10n.text("底部"))
            .accessibilityIdentifier("callSubtitlePositionToggle")
        } else {
            Button { player.cycleRepeatMode() } label: {
                Label(player.repeatMode.displayName, systemImage: player.repeatMode.iconName)
            }
            .disabled(player.isInCall)
            .accessibilityLabel(player.repeatMode.displayName)
            .accessibilityIdentifier("playbackRepeatMode")
        }
    }
}

private struct PlayerOptionLabelStyle: LabelStyle {
    let ink: Color?

    func makeBody(configuration: Configuration) -> some View {
        let label = VStack(spacing: 4) {
            configuration.icon.font(.system(size: 18))
            configuration.title.font(.caption).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        if let ink { label.foregroundStyle(ink) } else { label }
    }
}

struct PlayerSaveButtons: View {
    let item: PlaybackQueueItem?
    let favoriteWork: WorkRecord?
    let onFavorite: (WorkRecord) -> Void

    var body: some View {
        AddTrackToPlaylistButton(item: item)
        PlayerFavoriteButton(favoriteWork: favoriteWork, onFavorite: onFavorite)
    }
}

private struct PlayerFavoriteButton: View {
    @EnvironmentObject private var store: LibraryStore
    let favoriteWork: WorkRecord?
    let onFavorite: (WorkRecord) -> Void

    var body: some View {
        let isFavorite = favoriteWork.map { store.isWorkFavorite(id: $0.id) } ?? false
        Button { if let favoriteWork { onFavorite(favoriteWork) } } label: {
            Label(isFavorite ? L10n.text("已收藏") : L10n.text("收藏"), systemImage: isFavorite ? "heart.fill" : "heart")
        }
        .accessibilityLabel(isFavorite ? L10n.text("管理作品收藏") : L10n.text("收藏整个作品"))
        .accessibilityIdentifier("playerFavorite")
        .disabled(favoriteWork == nil)
    }
}

private struct AddTrackToPlaylistButton: View {
    let item: PlaybackQueueItem?
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.playlistAdditionSucceeded) private var onAdded
    @State private var pending: PlaybackQueueItem?

    var body: some View {
        let saved = item.map { item in
            store.playlistEntries.contains { item.mediaID != nil && $0.wholeMediaID == item.mediaID }
        } ?? false
        Button { pending = item } label: {
            Label(saved ? L10n.text("已加入列表") : L10n.text("加入列表"),
                  systemImage: saved ? "text.badge.checkmark" : "text.badge.plus")
        }
        .disabled(item?.mediaID == nil)
        .accessibilityLabel("加入播放列表")
        .accessibilityIdentifier("saveWholeTrack")
        .porcelainSheet(item: $pending) { PlaylistDestinationSheet(item: $0, onAdded: onAdded) }
    }
}
