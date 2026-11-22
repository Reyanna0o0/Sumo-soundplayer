import SwiftUI
import AVFoundation
import UIKit
import Combine

/// A silent, video-only preview. It never enters PlayerController or configures an audio session.
@MainActor
private final class CallFramingMedia: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var poster: UIImage?
    @Published private(set) var player: AVQueuePlayer?
    @Published private(set) var size = CGSize(width: 1, height: 1)
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    private var prepared: PreparedWorkVideo?
    private var generation = UUID()

    func load(url: URL?, kind: CallBackgroundKind) async {
        stop()
        let expected = generation
        image = nil; poster = nil; error = nil; size = CGSize(width: 1, height: 1)
        guard let url else { return }
        isLoading = true
        defer { if generation == expected { isLoading = false } }
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PreviewError(message: L10n.text("原显示文件暂时无法读取。原有设置已保留，可重新选择文件。"))
            }
            if kind == .image {
                let original = WorkAssetImporter.originalImageForCropping(at: url.path)
                guard let loaded = UIImage(contentsOfFile: original.path) else {
                    throw PreviewError(message: L10n.text("无法读取这张图片。原有设置已保留。"))
                }
                try Task.checkCancellation()
                guard generation == expected else { return }
                image = loaded; size = loaded.size
                return
            }
            let playable = try await PreparedWorkVideo.prepare(url)
            try Task.checkCancellation()
            let asset = AVURLAsset(url: playable.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw PreviewError(message: L10n.text("这份文件没有可显示的视频画面。"))
            }
            let timeRange = try await source.load(.timeRange)
            let naturalSize = try await source.load(.naturalSize)
            let transform = try await source.load(.preferredTransform)
            guard timeRange.duration.isNumeric, timeRange.duration.seconds > 0 else {
                throw PreviewError(message: L10n.text("无法读取这份视频的时长。"))
            }
            let composition = AVMutableComposition()
            guard let video = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw PreviewError(message: L10n.text("无法准备视频预览。"))
            }
            // Omit all audio tracks, so even a muted preview cannot take over the audio player.
            try video.insertTimeRange(timeRange, of: source, at: .zero)
            video.preferredTransform = transform
            let generator = AVAssetImageGenerator(asset: composition)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 800, height: 800)
            let thumbnail = try? await generator.image(at: .zero)
            try Task.checkCancellation()
            guard generation == expected else { return }
            let item = AVPlayerItem(asset: composition)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.volume = 0
            queue.preventsDisplaySleepDuringVideoPlayback = false
            queue.audiovisualBackgroundPlaybackPolicy = .pauses
            prepared = playable
            poster = thumbnail.map { UIImage(cgImage: $0.image) }
            let loop = AVPlayerLooper(player: queue, templateItem: item)
            looper = loop
            statusObservation = loop.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                guard observed.status == .failed else { return }
                Task { @MainActor in
                    guard let self, self.generation == expected else { return }
                    self.player?.pause()
                    self.error = L10n.text("此视频暂时无法循环预览。原有显示文件与设置已保留。")
                }
            }
            player = queue
            let transformed = naturalSize.applying(transform)
            size = CGSize(width: max(1, abs(transformed.width)), height: max(1, abs(transformed.height)))
            queue.play()
        } catch is CancellationError {
            // Closing a sheet must not turn cancellation into a persistent import error.
        } catch {
            guard generation == expected else { return }
            self.error = L10n.text("无法预览：\(error.localizedDescription) 原有设置已保留。")
        }
    }

    func setActive(_ active: Bool) {
        if active { player?.play() } else { player?.pause() }
    }

    func stop() {
        generation = UUID()
        player?.pause()
        statusObservation?.invalidate(); statusObservation = nil
        looper?.disableLooping(); looper = nil
        player?.removeAllItems(); player = nil
        prepared = nil
        isLoading = false
    }

    private struct PreviewError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}

private final class CallFramingPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct CallFramingPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> CallFramingPlayerUIView {
        let view = CallFramingPlayerUIView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }
    func updateUIView(_ view: CallFramingPlayerUIView, context: Context) {
        view.playerLayer.player = player
    }
    static func dismantleUIView(_ view: CallFramingPlayerUIView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

/// Original images remain untouched. Backgrounds fill by default; avatars fit.
struct CallFramingCanvas: View {
    let url: URL?
    var kind: CallBackgroundKind = .image
    @Binding var framing: CallFraming
    var allowsBlur = true
    var isInteractive = true
    var isPreviewActive = true
    var defaultContentMode: CallFramingContentMode = .fit
    @StateObject private var media = CallFramingMedia()
    @StateObject private var spatial = CallSpatialPresentation()
    @State private var outwardRenderer = CallImageOutwardRenderer()
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let viewport = geometry.size
            let horizontal = viewport.width / max(1, media.size.width)
            let vertical = viewport.height / max(1, media.size.height)
            let baseScale = (framing.contentMode ?? defaultContentMode) == .fill
                ? max(horizontal, vertical) : min(horizontal, vertical)
            let zoom = min(5, max(0.25, framing.zoom * Double(pinch)))
            let sourceSize = CGSize(width: media.size.width * baseScale * zoom,
                                    height: media.size.height * baseScale * zoom)
            let offset = CGSize(width: min(viewport.width / 2, max(-viewport.width / 2,
                                  CGFloat(framing.offsetX) * viewport.width / 2 + drag.width)),
                                height: min(viewport.height / 2, max(-viewport.height / 2,
                                  CGFloat(framing.offsetY) * viewport.height / 2 + drag.height)))
            let imageRect = CGRect(x: (viewport.width - sourceSize.width) / 2 + offset.width,
                                   y: (viewport.height - sourceSize.height) / 2 + offset.height,
                                   width: sourceSize.width, height: sourceSize.height)
            ZStack {
                Color.black
                if allowsBlur && framing.fillMode == .blur {
                    blurredFill(viewport: viewport)
                }
                if let renderer = spatial.renderer,
                   let rendered = renderer.image(pose: spatial.pose, rect: imageRect,
                        viewport: CGRect(origin: .zero, size: viewport), scale: min(2, displayScale), amount: spatial.amount) {
                    Image(uiImage: rendered).resizable().frame(width: viewport.width, height: viewport.height)
                } else if defaultContentMode == .fill, let image = media.image,
                   let rendered = outwardRenderer.render(image, in: imageRect,
                       viewport: CGRect(origin: .zero, size: viewport), outputScale: min(2, displayScale)) {
                    Image(uiImage: rendered).resizable()
                        .frame(width: viewport.width, height: viewport.height)
                } else {
                    content
                    .frame(width: sourceSize.width, height: sourceSize.height)
                    .mask {
                        if defaultContentMode == .fill {
                            CallImageEdgeMask(image: imageRect, viewport: CGRect(origin: .zero, size: viewport))
                        } else { Rectangle() }
                    }
                    .offset(offset)
                }
                if media.isLoading { ProgressView().tint(.white) }
                if spatial.isLoading { ProgressView("正在生成空间效果…").tint(.white).foregroundStyle(.white).font(.caption) }
                if let error = spatial.error {
                    VStack { Spacer(); Text(error).font(.caption).foregroundStyle(.white).padding(8).background(.black.opacity(0.65)) }
                }
                if let error = media.error {
                    Text(error).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center).padding()
                } else if url == nil {
                    Image(systemName: "photo").foregroundStyle(.white.opacity(0.55))
                        .accessibilityLabel("尚未选择显示图片")
                }
            }
            .frame(width: viewport.width, height: viewport.height)
            .clipped().contentShape(Rectangle())
            .gesture(DragGesture().updating($drag) { value, state, _ in
                guard isInteractive else { return }; state = value.translation
            }.onEnded { value in
                guard isInteractive, viewport.width > 0, viewport.height > 0 else { return }
                framing.offsetX = min(1, max(-1, framing.offsetX + Double(value.translation.width / viewport.width * 2)))
                framing.offsetY = min(1, max(-1, framing.offsetY + Double(value.translation.height / viewport.height * 2)))
            }, including: isInteractive ? .all : .none)
            .simultaneousGesture(MagnificationGesture().updating($pinch) { value, state, _ in
                guard isInteractive else { return }; state = value
            }.onEnded { value in
                guard isInteractive else { return }
                framing.zoom = min(5, max(0.25, framing.zoom * Double(value)))
            }, including: isInteractive ? .all : .none)
        }
        .task(id: (url?.absoluteString ?? "") + String(describing: kind)) {
            await media.load(url: url, kind: kind)
            media.setActive(scenePhase == .active && isPreviewActive)
        }
        .onChange(of: scenePhase) { _, phase in media.setActive(phase == .active && isPreviewActive) }
        .onChange(of: isPreviewActive) { _, active in media.setActive(scenePhase == .active && active) }
        .task(id: "\(url?.absoluteString ?? "")|\(spatialEnabled)") {
            await spatial.load(url: url, enabled: spatialEnabled)
        }
        .onDisappear { media.stop(); spatial.stop(); outwardRenderer.reset() }
        .accessibilityLabel("显示取景预览")
        .accessibilityIdentifier("callFramingCanvas")
        .accessibilityValue(String(format: L10n.text("缩放 %.3f 倍，水平偏移 %.3f，垂直偏移 %.3f"),
                                   framing.zoom, framing.offsetX, framing.offsetY))
    }

    private var spatialEnabled: Bool {
        defaultContentMode == .fill && kind == .image && framing.spatialEffectEnabled == true
            && isPreviewActive && scenePhase == .active
    }

    @ViewBuilder private var content: some View {
        if let image = media.image {
            Image(uiImage: image).resizable().scaledToFit()
        } else if let player = media.player {
            CallFramingPlayerLayer(player: player)
        }
    }

    @ViewBuilder private func blurredFill(viewport: CGSize) -> some View {
        let fillScale = max(viewport.width / max(1, media.size.width),
                            viewport.height / max(1, media.size.height))
        // Only one AVPlayerLayer renders the movie; the fill uses its poster frame.
        // Sharing one AVPlayer across two layers can leave one of them blank.
        if let image = media.image ?? media.poster {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: media.size.width * fillScale, height: media.size.height * fillScale)
                .blur(radius: 22)
                .overlay(Color.black.opacity(0.18))
                .frame(width: viewport.width, height: viewport.height).clipped()
        }
    }
}

enum CallFramingPreviewKind {
    case avatar, background, local

    var aspectRatio: CGFloat {
        switch self { case .background: return 9 / 19.5; case .local: return 3 / 4; case .avatar: return 1 }
    }
    var defaultContentMode: CallFramingContentMode { self == .background ? .fill : .fit }
}

/// Uses the same canvas and image framing as the call. Decorations never intercept editing gestures.
struct CallFramingPreview: View {
    let url: URL?
    var kind: CallBackgroundKind = .image
    @Binding var framing: CallFraming
    var previewKind: CallFramingPreviewKind = .avatar
    var isInteractive = true
    var isPreviewActive = true
    var allowsBlur = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CallFramingCanvas(url: url, kind: kind, framing: $framing,
                    allowsBlur: allowsBlur, isInteractive: isInteractive,
                    isPreviewActive: isPreviewActive, defaultContentMode: previewKind.defaultContentMode)
                if previewKind == .background {
                    let scale = geometry.size.width / 390
                    LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.72)],
                                   startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                    VStack(spacing: 0) {
                        VStack(spacing: 5 * scale) {
                            Text("通话预览").font(.system(size: 22 * scale, weight: .semibold))
                            Text("通话中").font(.system(size: 13 * scale))
                        }.padding(.top, 48 * scale)
                        Spacer(minLength: 0)
                        HStack(spacing: 25 * scale) {
                            previewButton("video.fill", scale: scale)
                            previewButton("mic.fill", scale: scale)
                            previewButton("speaker.wave.2.fill", scale: scale)
                            previewButton("person.crop.rectangle", scale: scale)
                        }
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 22 * scale)).frame(width: 60 * scale, height: 60 * scale)
                            .background(.red, in: Circle()).padding(.top, 25 * scale)
                        Text("字幕叠在画面上，背景仍铺满")
                            .font(.system(size: 14 * scale)).padding(.top, 27 * scale)
                        HStack {
                            ForEach(["speedometer", "arrow.up.arrow.down", "moon", "text.badge.plus", "heart", "list.bullet"], id: \.self) {
                                Image(systemName: $0).frame(maxWidth: .infinity)
                            }
                        }.font(.system(size: 17 * scale)).padding(.top, 23 * scale)
                        .padding(.bottom, 48 * scale)
                    }.padding(.horizontal, 22 * scale).foregroundStyle(.white).allowsHitTesting(false)
                }
            }.clipShape(RoundedRectangle(cornerRadius: previewKind == .background ? 24 : 16))
                .overlay(RoundedRectangle(cornerRadius: previewKind == .background ? 24 : 16)
                    .stroke(.white.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
        }
        .aspectRatio(previewKind.aspectRatio, contentMode: .fit)
        .accessibilityIdentifier("callAppearancePreview")
    }

    private func previewButton(_ name: String, scale: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: 22 * scale))
            .frame(width: 56 * scale, height: 56 * scale)
            .background(.white.opacity(0.16), in: Circle())
    }
}

struct CallFramingSheet: View {
    let title: String
    let url: URL?
    var kind: CallBackgroundKind = .image
    @Binding var framing: CallFraming
    var allowsBlur = true
    var previewKind: CallFramingPreviewKind = .avatar
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CallFraming

    init(title: String, url: URL?, kind: CallBackgroundKind = .image,
         framing: Binding<CallFraming>, allowsBlur: Bool = true,
         previewKind: CallFramingPreviewKind = .avatar) {
        self.title = title; self.url = url; self.kind = kind
        _framing = framing; self.allowsBlur = allowsBlur; self.previewKind = previewKind
        var initial = framing.wrappedValue
        if !allowsBlur { initial.fillMode = .black }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 18) {
                        CallFramingPreview(url: url, kind: kind, framing: $draft,
                            previewKind: previewKind, allowsBlur: allowsBlur)
                            .frame(maxWidth: previewKind == .background
                                ? min(330, max(210, geometry.size.height * 0.6 * previewKind.aspectRatio)) : 320)
                            .frame(maxWidth: .infinity)
                        Picker("显示方式", selection: Binding(get: {
                            draft.contentMode ?? previewKind.defaultContentMode
                        }, set: { draft.contentMode = $0 })) {
                            Text("铺满画面").tag(CallFramingContentMode.fill)
                            Text("完整显示").tag(CallFramingContentMode.fit)
                        }.pickerStyle(.segmented).accessibilityIdentifier("callFramingContentMode")
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                            Slider(value: $draft.zoom, in: 0.25...5).accessibilityLabel("显示缩放")
                                .accessibilityIdentifier("callFramingZoom")
                            Image(systemName: "plus.magnifyingglass")
                        }
                        if allowsBlur {
                            Picker("空白区域", selection: $draft.fillMode) {
                                Text("黑色填边").tag(CallFillMode.black)
                                Text("模糊填边").tag(CallFillMode.blur)
                            }.pickerStyle(.segmented)
                        }
                        Text(previewKind == .local
                            ? L10n.text("这里按你的头像小窗比例显示。拖动或双指缩放；缩小后可保留黑边。")
                            : L10n.text("直接拖动或双指缩放取景。铺满会裁去边缘，完整显示可保留整张图片；原文件不变。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button("铺满并居中") { reset(.fill) }
                                .accessibilityIdentifier("callFramingFill")
                            Spacer()
                            Button("完整显示并居中") { reset(.fit) }
                                .accessibilityIdentifier("callFramingReset")
                        }.font(.subheadline)
                        if previewKind == .background && kind == .image {
                            Toggle("空间效果 · 增强", isOn: Binding(get: { draft.spatialEffectEnabled == true },
                                set: { draft.spatialEffectEnabled = $0 }))
                                .accessibilityIdentifier("callFramingSpatialToggle")
                            Text("轻晃手机查看图片的前后层次。开启时略微放大，关闭恢复原取景；原图片不变。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(20).frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") {
                        if !allowsBlur { draft.fillMode = .black }
                        framing = draft; dismiss()
                    }.accessibilityIdentifier("saveCallFraming")
                }
            }
        }
    }

    private func reset(_ mode: CallFramingContentMode) {
        draft.contentMode = mode; draft.zoom = 1; draft.offsetX = 0; draft.offsetY = 0
    }
}
