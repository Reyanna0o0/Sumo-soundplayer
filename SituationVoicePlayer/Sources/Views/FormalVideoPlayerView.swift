import AVFoundation
import SwiftUI

struct PlaybackPresentationView: View {
    @EnvironmentObject private var player: PlayerController
    var body: some View {
        ZStack {
            if player.isInCall { SimulatedCallView() }
            else if player.isVideo { FormalVideoPlayerView() }
            else { PlayerView().porcelainSurface() }
        }
        .background(CallOrientationWindowBridge(player: player).allowsHitTesting(false))
        .playlistAdditionFeedback()
    }
}

/// Full-screen media playback; no document preview/navigation container.
struct FormalVideoPlayerView: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var favoriteWork: WorkRecord?
    @State private var favoriteTarget: WorkRecord?
    @State private var showSleepTimer = false
    @State private var controlsVisible = true
    @State private var scrub: Double?
    @State private var showQueue = false

    var body: some View {
        ZStack {
            if AppTheme.isPurple {
                AppTheme.purpleBackdrop.ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            ZoomableVideoSurface(player: player.videoPlayer, scale: $player.videoScale,
                                 showsBackdrop: AppTheme.isPurple)
                .ignoresSafeArea()
                .onTapGesture { controlsVisible.toggle() }
                .accessibilityIdentifier("formalVideoSurface")
            if player.isLoadingMedia { ProgressView("正在准备视频…").tint(.white).foregroundStyle(.white) }
            if let error = player.errorMessage {
                VStack(spacing: 16) {
                    Text(error).multilineTextAlignment(.center)
                    Button("重试") { player.resume() }
                }.padding().foregroundStyle(.white)
            }
            if controlsVisible {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.down").padding(12) }
                            .accessibilityLabel("收起播放器").accessibilityIdentifier("collapseVideo")
                        Text(player.currentItem?.trackTitle ?? L10n.text("视频")).lineLimit(2).font(.subheadline)
                        Spacer()
                        Button { player.beginCall() } label: { Image(systemName: "phone") }
                            .accessibilityLabel("模拟通话").accessibilityIdentifier("startCall")
                        Button { player.videoScale = 1 } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                            .accessibilityLabel("恢复视频取景")
                    }
                    .padding(10).background(.black.opacity(0.55))
                    Spacer()
                    VStack(spacing: verticalSizeClass == .compact ? 4 : 12) {
                        Slider(value: Binding(get: { scrub ?? Double(player.positionMS) }, set: { scrub = $0 }),
                               in: 0...Double(max(1, player.durationMS))) { editing in
                            if !editing, let scrub { player.seek(to: Int(scrub)); self.scrub = nil }
                        }.disabled(player.isLoadingMedia)
                            .accessibilityLabel("视频进度").accessibilityIdentifier("videoProgress")
                        HStack {
                            Text(SubtitleTime.clock(Int(scrub ?? Double(player.positionMS))))
                            Spacer()
                            Text(SubtitleTime.clock(player.durationMS))
                        }.font(.caption.monospacedDigit())
                        HStack(spacing: 34) {
                            Button { player.previous() } label: { Image(systemName: "backward.end.fill") }
                                .accessibilityLabel("上一个")
                            Button { player.togglePlayPause() } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                            }.accessibilityLabel(player.isPlaying ? L10n.text("暂停视频") : L10n.text("播放视频")).accessibilityIdentifier("videoPlayPause")
                            Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                                .accessibilityLabel("下一个")
                        }
                        PlayerOptionsRow(favoriteWork: favoriteWork, onFavorite: { favoriteTarget = $0 },
                                         onQueue: { showQueue = true }, onSleep: { showSleepTimer = true })
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, verticalSizeClass == .compact ? 6 : 14)
                    .background(.black.opacity(0.6))
                }.foregroundStyle(.white).tint(.white)
            }
        }
        .statusBarHidden(!controlsVisible)
        .porcelainSheet(isPresented: $showQueue) { PlaybackQueueSheet() }
        .porcelainSheet(isPresented: $showSleepTimer) { SleepTimerSheet() }
        .porcelainSheet(item: $favoriteTarget) { work in WorkFavoritePicker(workID: work.id) }
        .onChange(of: player.currentItem?.workID, initial: true) { refreshFavoriteWork() }
        .onChange(of: store.contentRevision) { refreshFavoriteWork() }
        .onChange(of: player.currentItem?.id) { _, _ in scrub = nil; controlsVisible = true }
    }

    private func refreshFavoriteWork() {
        favoriteWork = player.currentItem.flatMap { try? store.work(id: $0.workID) }
    }
}

struct ZoomableVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    @Binding var scale: CGFloat
    var fillsFrame = false
    var showsBackdrop = false

    func makeUIView(context: Context) -> VideoZoomScrollView {
        let view = VideoZoomScrollView()
        view.backgroundColor = showsBackdrop ? .clear : .black
        view.surface.playerLayer.player = player
        view.surface.playerLayer.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        view.accessibilityValue = String(format: "%.2f", scale)
        return view
    }
    func updateUIView(_ view: VideoZoomScrollView, context: Context) {
        view.backgroundColor = showsBackdrop ? .clear : .black
        view.surface.playerLayer.player = player
        view.surface.playerLayer.videoGravity = fillsFrame ? .resizeAspectFill : .resizeAspect
        view.scaleChanged = { scale = $0 }
        if !view.isZooming, abs(view.zoomScale - scale) > 0.01 { view.setZoomScale(scale, animated: false) }
    }
}

final class VideoSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class VideoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let surface = VideoSurfaceView()
    var scaleChanged: ((CGFloat) -> Void)?
    private var lastSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 4; bouncesZoom = false
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        backgroundColor = .black
        isAccessibilityElement = true
        accessibilityLabel = L10n.text("视频画面")
        accessibilityIdentifier = "formalVideoSurface"
        surface.playerLayer.videoGravity = .resizeAspect
        addSubview(surface)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            let previous = zoomScale
            lastSize = bounds.size
            setZoomScale(1, animated: false)
            surface.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
            setZoomScale(previous, animated: false)
        }
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { surface }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        accessibilityValue = String(format: "%.2f", scale)
        scaleChanged?(scale)
    }
}
