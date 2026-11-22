import SwiftUI

struct RootView: View {
    enum Tab: Hashable {
        case library, playlist, statistics, settings
    }

    @StateObject private var player = PlayerController()
    @StateObject private var store = LibraryStore()
    @StateObject private var subtitles = SubtitleController()
    @StateObject private var pictureInPicture = AppPictureInPictureCoordinator()
    @StateObject private var launch = LaunchExperience.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CoverPrivacy.settingKey) private var privacyEnabled = false
    @State private var selection: Tab
    @State private var purpleViewport: CGRect = .zero

    init(initialTab: Tab = .library) {
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            LibraryView()
                .withMiniPlayer()
                .modifier(AppContentTheme())
                .tabItem { tabLabel("媒体库", systemImage: "square.grid.2x2") }
                .tag(Tab.library)

            SavedPlaylistView()
                .withMiniPlayer(backdrop: .clear)
                .modifier(AppContentTheme())
                .background { PlaylistBackdrop() }
                .toolbarBackground(AppTheme.isPurple ? .visible : .hidden, for: .tabBar)
                .tabItem { tabLabel("播放列表", systemImage: "music.note.list") }
                .tag(Tab.playlist)

            StatisticsView()
                .withMiniPlayer(backdrop: AppTheme.porcelainBackground)
                .modifier(AppContentTheme())
                .tabItem { tabLabel("统计", systemImage: "chart.bar") }
                .tag(Tab.statistics)

            SettingsView()
                .withMiniPlayer()
                .modifier(AppContentTheme())
                .tabItem { tabLabel("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(AppTheme.isPurple ? AppTheme.purplePlaybackIndicator : AppTheme.optionalTint)
        .preferredColorScheme(AppearanceSelection.shared.palette.preferredColorScheme)
        .overlay {
            if selection == .library, case .done(let works, let tracks, let subtitles, 0, 0) = store.phase, works > 0 {
                let detail = LibraryView.summaryText(works: works, tracks: tracks, subtitles: subtitles,
                                                     unmatched: 0, pdfSummary: store.scriptImportSummary)
                ImportSuccessToast(detail: detail)
                    .accessibilityIdentifier("libraryImportSuccess")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        // 注意：mini player 必须挂在"每个页面内部"而不是 TabView 外层。
        // 挂在 TabView 上时 safeAreaInset 会盖住系统标签栏（底部三个按钮被遮住）。
        .fullScreenCover(isPresented: $player.isPlayerSheetPresented) {
            PlaybackPresentationView()
                .modifier(AppContentTheme())
        }
        .environmentObject(player)
        .environmentObject(store)
        .environmentObject(subtitles)
        .environmentObject(pictureInPicture)
        .environment(\.appAppearanceColorScheme, AppearanceSelection.shared.palette.preferredColorScheme ?? colorScheme)
        .environment(\.purpleViewport, purpleViewport)
        .background {
            if AppTheme.isPurple {
                Color.clear
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { purpleViewport = $0 }
                    .ignoresSafeArea(.container)
            }
        }
        .accessibilityHidden(launch.isShowing)
        .overlay {
            if launch.isShowing {
                LaunchArtworkView { launch.finish() }
                    .ignoresSafeArea()
                    // LaunchArtworkView fades to transparent before completion;
                    // removing its empty layer must not add a second transition.
                    .transition(.identity)
                    .zIndex(100)
            }
        }
        .onChange(of: selection) { _, tab in
            if tab == .statistics { player.flushListeningStatistics() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { player.cancelCallConnectionIfNeeded() }
            pictureInPicture.sceneChanged(phase)
            if phase == .background { player.flushListeningStatistics() }
            if phase == .background {
                OpeningVoicePlayer.shared.stop()
                launch.finish()
            }
        }
        .onChange(of: privacyEnabled) { player.refreshLockScreenPrivacy() }
        .onChange(of: AppLanguageSelection.shared.code) {
            player.refreshLockScreenPrivacy()
            pictureInPicture.interfaceLanguageChanged()
        }
        .onReceive(store.importedSubtitleTracks) { ids in
            guard let id = subtitles.loadedTrackID, ids.contains(id) else { return }
            subtitles.forceReload()
            subtitles.update(positionMS: player.positionMS)
        }
        .task {
            store.bootstrap()
            player.attach(store: store)
            if let repo = store.subtitleRepository {
                subtitles.attach(repository: repo)
            }
            pictureInPicture.attach(player: player, store: store, subtitles: subtitles)
            launch.begin(store: store)
            #if DEBUG
            if CommandLine.arguments.contains("-openPlayer") {
                player.isPlayerSheetPresented = true
            }
            #endif
        }
    }
    @ViewBuilder private func tabLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        // The system tab bar otherwise applies its own tint to inactive glyphs.
        if AppTheme.isPurple, let symbol = UIImage(systemName: systemImage + ".fill") ?? UIImage(systemName: systemImage) {
            let colored = symbol.withTintColor(UIColor(AppTheme.iconTint), renderingMode: .alwaysOriginal)
            Label { Text(title) } icon: { Image(uiImage: colored).renderingMode(.original) }
        } else {
            Label(title, systemImage: systemImage)
        }
    }
}

#Preview {
    RootView()
}

/// 把迷你播放器挂到页面底部（在标签栏之上）
struct MiniPlayerInset: ViewModifier {
    let backdrop: Color
    @EnvironmentObject private var player: PlayerController
    @State private var miniPlayerHeight: CGFloat = 0

    func body(content: Content) -> some View {
        // 给整个导航栈分配实际剩余高度。外层 safeAreaInset 在部分导航/滚动
        // 容器中只改变安全区报告，最后一行仍会滑到播放器下面。
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                // Keep the last control's full touch area clear of both the
                // floating system tab bar and the optional mini player.
                .padding(.bottom, 12)
            if player.currentItem != nil {
                MiniPlayerView()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("miniPlayerBar")
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height.isFinite, height > 0, abs(miniPlayerHeight - height) > 0.5 else { return }
                        miniPlayerHeight = height
                        #if DEBUG
                        if Bundle.main.bundleIdentifier == "io.github.gloriaguuuu.simo.call1111sim" {
                            DebugLog.write("QA mini-player measured height=\(height)")
                        }
                        #endif
                    }
            }
        }
        .backgroundPreferenceValue(PorcelainTabBackdrop.self) { detailIsVisible in
            if AppTheme.isPurple {
                PurplePageBackdrop()
                    .toolbarBackground(AppTheme.purpleTabSurface, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
            } else {
                (AppTheme.usesCustomPalette ? (detailIsVisible ? AppTheme.porcelainBackground : backdrop) : Color.clear)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .environment(\.miniPlayerHeight, player.currentItem == nil ? 0 : miniPlayerHeight)
    }
}

/// Include the tab bar safe area in the active work detail's page color.
struct PorcelainTabBackdrop: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct MiniPlayerHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Scoped to the current tab/window; full-screen playback does not consume it.
    var miniPlayerHeight: CGFloat {
        get { self[MiniPlayerHeightKey.self] }
        set { self[MiniPlayerHeightKey.self] = newValue }
    }
}

extension View {
    func withMiniPlayer(backdrop: Color = AppTheme.background) -> some View {
        modifier(MiniPlayerInset(backdrop: backdrop))
    }
}
