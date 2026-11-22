import SwiftUI

/// A call-shaped presentation of the existing player. Camera controls only show the user's saved image.
struct SimulatedCallView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var subtitles: SubtitleController
    @EnvironmentObject private var pictureInPicture: AppPictureInPictureCoordinator
    @AppStorage("hibiki.call.subtitleInMiddle") private var subtitleInMiddle = false
    @AppStorage(CallInterfacePreferences.realisticLabelsKey) private var realisticLabels = false
    @State private var appearance: ResolvedCallAppearance?
    @State private var appearanceError: String?
    @State private var localImageURL: URL?
    @State private var localFraming = CallFraming()
    @State private var localImageError: String?
    @State private var localCenter: CGPoint?
    @GestureState private var localDrag: CGSize = .zero
    @State private var initialVideoScale: CGFloat?
    @State private var favoriteWork: WorkRecord?
    @State private var favoriteTarget: WorkRecord?
    @State private var showQueue = false
    @State private var showSubtitleStyle = false
    @State private var utilitiesCollapsed = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let fullSize = CGSize(width: size.width,
                height: size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            let displaySize = fullSize
            let displayOffset = (geometry.safeAreaInsets.bottom - geometry.safeAreaInsets.top) / 2
            let window = localWindowSize(in: fullSize)
            ZStack {
                Color.black.ignoresSafeArea()
                remoteDisplay(in: displaySize)
                    .animation(.easeInOut(duration: 0.42), value: player.callUsesVideo)
                    .offset(y: displayOffset)
                    // The background may draw outside the safe area, but must
                    // not enlarge the layout proposal for controls or local image.
                    .frame(width: size.width, height: size.height)
                // Shade one continuous full-screen surface. A gradient attached
                // to the safe-area header starts abruptly below the status bar.
                LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0),
                                       .init(color: .clear, location: min(1, 190 / max(1, displaySize.height))),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .offset(y: displayOffset)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                if player.callPhase == .connecting && !player.callUsesVideo { dialingHalo(in: size) }
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .clear, location: 0.4),
                                       .init(color: .black.opacity(0.55), location: 0.65),
                                       .init(color: .black.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
                overlay(in: size, backgroundSize: displaySize, backgroundOffset: displayOffset)
                    .frame(width: size.width, height: size.height)
                if player.callShowsLocalImage {
                    let center = clamp(localCenter ?? initialLocalCenter(in: fullSize, window: window),
                                       in: fullSize, window: window)
                    let visible = clamp(CGPoint(x: center.x + localDrag.width, y: center.y + localDrag.height),
                                        in: fullSize, window: window)
                    localWindow
                        .frame(width: window.width, height: window.height)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.5), lineWidth: 1))
                        .position(x: visible.x, y: visible.y - geometry.safeAreaInsets.top)
                        .gesture(DragGesture().updating($localDrag) { value, state, _ in
                            state = value.translation
                        }.onEnded { value in
                            let moved = CGPoint(x: center.x + value.translation.width, y: center.y + value.translation.height)
                            localCenter = clamp(moved, in: fullSize, window: window)
                            if let localCenter {
                                pictureInPicture.localPosition = CGPoint(x: localCenter.x / max(1, fullSize.width),
                                                                          y: localCenter.y / max(1, fullSize.height))
                                pictureInPicture.pip.refreshFrame()
                            }
                        })
                        .accessibilityLabel("我的头像，可拖动到全屏任意位置")
                        .zIndex(10)
                        .accessibilityIdentifier("callLocalWindow")
                }
            }
            .frame(width: size.width, height: size.height)
            .onChange(of: fullSize) { _, newSize in
                syncLocalCenter(in: newSize)
            }
            .onChange(of: displaySize, initial: true) { _, newSize in pictureInPicture.setCallSize(newSize) }
            .onAppear { syncLocalCenter(in: fullSize) }

        }
        .foregroundStyle(.white)
        .task(id: player.callWorkID) { loadAppearance() }
        .onChange(of: store.contentRevision) { _, _ in loadAppearance() }
        .onChange(of: player.callShowsLocalImage) { _, shown in
            if shown { loadLocalImage() }
            pictureInPicture.pip.refreshFrame()
        }
        .onChange(of: player.currentItem?.id, initial: true) { _, _ in refreshFavoriteWork() }
        .onChange(of: store.contentRevision) { _, _ in refreshFavoriteWork() }
        .sheet(item: $favoriteTarget) { WorkFavoritePicker(workID: $0.id) }
        .sheet(isPresented: $showQueue) { PlaybackQueueSheet() }
        .sheet(isPresented: $showSubtitleStyle) { SubtitleStyleSheet(mode: .call) }
        .onAppear { pictureInPicture.pageVisibility(.call, visible: true) }
        .onDisappear {
            pictureInPicture.pageVisibility(.call, visible: false)
        }
    }

    @ViewBuilder private func remoteDisplay(in size: CGSize) -> some View {
        if pictureInPicture.hasCallSurface {
            SystemPictureInPictureSurface(controller: pictureInPicture.pip)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(MagnifyGesture().onChanged { value in
                    guard player.callUsesVideo, player.isVideo, appearance?.prefersWorkVideo == true else { return }
                    if initialVideoScale == nil { initialVideoScale = player.videoScale }
                    player.videoScale = min(4, max(1, (initialVideoScale ?? 1) * value.magnification))
                    pictureInPicture.pip.refreshFrame()
                }.onEnded { _ in initialVideoScale = nil })
                .accessibilityHidden(true)
        } else if player.callUsesVideo {
            if player.isVideo && appearance?.prefersWorkVideo == true {
                ZoomableVideoSurface(player: player.videoPlayer, scale: $player.videoScale, fillsFrame: true)
                    .frame(width: size.width, height: size.height)
            } else if let appearance, let background = appearance.backgroundURL {
                CallFramingCanvas(url: background, kind: appearance.backgroundKind,
                                  framing: .constant(appearance.backgroundFraming), isInteractive: false,
                                  isPreviewActive: player.callPhase == .connected, defaultContentMode: .fill)
                    .frame(width: size.width, height: size.height)
            }
        } else if let appearance, let avatar = appearance.avatarURL {
            let rect = CallScreenLayout.avatarRect(in: size)
            CallFramingCanvas(url: avatar, framing: .constant(appearance.avatarFraming), isInteractive: false)
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: rect.width * 0.09))
                .position(x: rect.midX, y: rect.midY)
                .accessibilityIdentifier("callRemoteAvatar")
        } else {
            let rect = CallScreenLayout.avatarRect(in: size)
            Image(systemName: "person.crop.circle")
                .resizable().scaledToFit().foregroundStyle(.white.opacity(0.65))
                .frame(width: rect.width * 0.55, height: rect.height * 0.55)
                .position(x: rect.midX, y: rect.midY)
                .accessibilityLabel("未设置通话头像")
                .accessibilityIdentifier("callRemoteAvatarPlaceholder")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(appearance?.name ?? player.currentWorkTitle)
                .font(.title2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                .accessibilityIdentifier("callDisplayName")
            HStack(spacing: 8) {
                if player.callPhase == .connecting {
                    Image(systemName: "phone.arrow.up.right.fill")
                        .symbolEffect(.pulse, options: .repeating)
                }
                Text(phaseTitle).font(.subheadline)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("callPhase")
            }
            if let appearanceError {
                Text(appearanceError).font(.footnote).multilineTextAlignment(.center)
                    .accessibilityIdentifier("callAppearanceError")
            }
            if let error = player.errorMessage {
                Text(error).font(.footnote).multilineTextAlignment(.center)
                    .accessibilityIdentifier("callPlaybackError")
            }
            if let message = pictureInPicture.message {
                Text(message).font(.footnote).multilineTextAlignment(.center)
                    .accessibilityIdentifier("callPiPMessage")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)
        .allowsHitTesting(false)
    }

    private func overlay(in size: CGSize, backgroundSize: CGSize, backgroundOffset: CGFloat) -> some View {
        let compact = CallScreenLayout.isLandscape(size)
        return CallOverlayLayout(size: size, subtitleInMiddle: subtitleInMiddle) {
            header.clipped()
            CallSubtitleText(content: CallSubtitleContent(cue: subtitles.currentCue,
                hasTimedCues: subtitles.cues.contains(where: \.hasTiming), style: subtitles.callStyle),
                fontSize: subtitles.callStyle.fontSize)
            controls(compact: compact, backgroundSize: backgroundSize, backgroundOffset: backgroundOffset)
            hangup(compact: compact).frame(maxWidth: .infinity)
            utilities
        }
        .animation(.easeInOut(duration: 0.25), value: subtitleInMiddle)
    }

    private func controls(compact: Bool, backgroundSize: CGSize, backgroundOffset: CGFloat) -> some View {
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            callButton(title: player.callUsesVideo ? L10n.text("切换语音") : L10n.text("切换视频"),
                       symbol: player.callUsesVideo ? "phone.fill" : "video.fill",
                       identifier: "callVideoMode", compact: compact, enabled: player.callPhase == .connected) {
                pictureInPicture.toggleCallVideoPresentation()
            }
            callButton(title: realisticLabels ? L10n.text("麦克风") : (player.isPlaying ? L10n.text("暂停播放") : L10n.text("继续播放")),
                       symbol: player.isPlaying ? "mic.fill" : "mic.slash.fill",
                       identifier: "callPlaybackToggle", compact: compact, enabled: player.callPhase == .connected) {
                player.togglePlayPause()
            }
            .accessibilityValue(player.isPlaying ? L10n.text("正在播放") : L10n.text("已暂停"))
            .accessibilityHint("控制当前音频播放，不使用麦克风")
            AudioOutputRouteButton(outputName: player.audioOutputName, compact: compact)
            callButton(title: realisticLabels ? (player.callShowsLocalImage ? L10n.text("关闭摄像头") : L10n.text("打开摄像头")) : L10n.text("我的头像"),
                       symbol: realisticLabels ? (player.callShowsLocalImage ? "video.fill" : "video.slash.fill")
                           : (player.callShowsLocalImage ? "person.crop.rectangle.fill" : "person.crop.rectangle"),
                       identifier: "callCamera", compact: compact, enabled: player.callPhase == .connected) {
                player.callShowsLocalImage.toggle()
            }
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    private func hangup(compact: Bool) -> some View {
        callButton(title: player.callPhase == .connecting ? L10n.text("取消") : L10n.text("挂断"),
                   symbol: "phone.down.fill", identifier: "callHangup", compact: compact, isDestructive: true) {
            player.endCall()
        }.frame(width: 100)
    }

    private var utilities: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.28)) { utilitiesCollapsed.toggle() }
            } label: {
                Image(systemName: utilitiesCollapsed ? "chevron.right" : "chevron.left")
                    .font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .foregroundStyle(.white)
                    .background {
                        if !utilitiesCollapsed { Capsule().fill(.ultraThinMaterial) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(utilitiesCollapsed ? L10n.text("展开底部工具栏") : L10n.text("收起底部工具栏"))
            .accessibilityIdentifier("callUtilitiesToggle")
            .accessibilityValue(utilitiesCollapsed ? L10n.text("已收起") : L10n.text("已展开"))
            if !utilitiesCollapsed {
                PlayerOptionsRow(favoriteWork: favoriteWork, onFavorite: { favoriteTarget = $0 },
                                 onQueue: { showQueue = true }, onSubtitleStyle: { showSubtitleStyle = true },
                                 callSubtitleInMiddle: subtitleInMiddle, onCallSubtitlePosition: { subtitleInMiddle.toggle() },
                                 callSpatialEnabled: appearance?.backgroundFraming.spatialEffectEnabled == true,
                                 callSpatialAvailable: canUseSpatialEffect, onCallSpatialToggle: toggleSpatialEffect)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            if utilitiesCollapsed { Spacer(minLength: 0) }
        }
        .environment(\.colorScheme, .dark).tint(.cyan)
        .frame(maxWidth: 660).frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { value in
            guard value.translation.width < -45, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
            withAnimation(.easeInOut(duration: 0.28)) { utilitiesCollapsed = true }
        })
    }

    private func refreshFavoriteWork() {
        favoriteWork = player.currentItem.flatMap { try? store.work(id: $0.workID) }
    }

    private var canUseSpatialEffect: Bool {
        player.callUsesVideo && appearance?.backgroundKind == .image && appearance?.backgroundURL != nil
            && !(player.isVideo && appearance?.prefersWorkVideo == true)
    }

    private func toggleSpatialEffect() {
        guard canUseSpatialEffect, let id = player.callWorkID, let work = try? store.work(id: id) else { return }
        do {
            try store.setCallSpatialEffect(appearance?.backgroundFraming.spatialEffectEnabled != true, for: work)
            loadAppearance()
        } catch { appearanceError = error.localizedDescription }
    }

    private func callButton(title: String, symbol: String, identifier: String,
                            compact: Bool = false, enabled: Bool = true, isDestructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: compact ? 5 : 9) {
                Image(systemName: symbol).font(compact ? .title3 : .title2)
                    .frame(width: compact ? 48 : 60, height: compact ? 48 : 60)
                    .background {
                        if isDestructive { Circle().fill(.red) }
                        else {
                            Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
                        }
                    }
                Text(title).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            }.frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(title).accessibilityIdentifier(identifier)
    }

    private var phaseTitle: String {
        switch player.callPhase {
        case .inactive: return L10n.text("通话已结束")
        case .connecting: return L10n.text("正在呼叫…")
        case .connected: return L10n.text("通话中")
        }
    }

    private var localWindow: some View {
        VStack(spacing: 0) {
            if let localImageURL {
                CallFramingCanvas(url: localImageURL, framing: .constant(localFraming),
                                  allowsBlur: false, isInteractive: false)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.rectangle").font(.title3)
                    if localImageError != nil {
                        Text("图片暂不可用").font(.caption2).multilineTextAlignment(.center)
                    }
                }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadAppearance() {
        appearance = nil; appearanceError = nil
        do {
            guard let id = player.callWorkID, let repository = store.repository,
                  let work = try repository.work(id: id) else {
                appearanceError = L10n.text("暂时无法读取这份作品的通话显示设置。")
                loadLocalImage(); return
            }
            appearance = try store.resolvedCallAppearance(for: work)
        } catch {
            appearanceError = L10n.text("无法读取通话显示：\(error.localizedDescription) 原有设置已保留。")
        }
        loadLocalImage()
    }

    private func loadLocalImage() {
        localImageURL = nil; localImageError = nil
        do {
            let profile = try store.callProfile(ownerKind: .localUser, id: 0)
            localFraming = profile.avatarFraming
            localFraming.fillMode = .black
            if profile.avatarMode == .custom { localImageURL = store.callAssetURL(profile.avatarAssetPath) }
        } catch {
            localImageError = L10n.text("暂时无法读取我的头像，原有设置已保留。")
        }
    }

    private func dialingHalo(in size: CGSize) -> some View {
        let rect = CallScreenLayout.avatarRect(in: size)
        return TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            RoundedRectangle(cornerRadius: rect.width * 0.1)
                .stroke(.white.opacity(0.32 * (1 - phase)), lineWidth: 2)
                .frame(width: rect.width + 8 + 26 * phase, height: rect.height + 8 + 26 * phase)
                .position(x: rect.midX, y: rect.midY)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private func localWindowSize(in size: CGSize) -> CGSize {
        let width = min(118, max(72, size.width * 0.28), max(1, size.width - 16))
        return CGSize(width: width, height: min(width * 4 / 3, max(1, size.height - 16)))
    }

    private func syncLocalCenter(in size: CGSize) {
        let window = localWindowSize(in: size)
        let center = clamp(localCenter ?? initialLocalCenter(in: size, window: window), in: size, window: window)
        localCenter = center
        pictureInPicture.localPosition = CGPoint(x: center.x / max(1, size.width), y: center.y / max(1, size.height))
        pictureInPicture.pip.refreshFrame()
    }

    private func initialLocalCenter(in size: CGSize, window: CGSize) -> CGPoint {
        CGPoint(x: size.width - window.width / 2 - 8, y: min(size.height / 2, window.height / 2 + 110))
    }

    private func clamp(_ point: CGPoint, in size: CGSize, window: CGSize) -> CGPoint {
        let minX = min(size.width / 2, window.width / 2 + 8)
        let minY = min(size.height / 2, window.height / 2 + 8)
        return CGPoint(x: min(max(minX, size.width - minX), max(minX, point.x)),
                       y: min(max(minY, size.height - minY), max(minY, point.y)))
    }

}
