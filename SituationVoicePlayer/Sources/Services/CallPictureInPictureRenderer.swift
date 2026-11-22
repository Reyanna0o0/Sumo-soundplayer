import UIKit
import AVFoundation
import CoreImage
import ImageIO

/// Owns only call decoration resources. The caller keeps this object alive for the whole PiP session.
/// The formal player is observed through a video output, never played, paused, or replaced here.
@MainActor
final class CallPictureInPictureRenderer {
    private(set) var preparationError: String?
    private(set) var frameStatusMessage: String?
    private var appearance: ResolvedCallAppearance?
    private var avatar: UIImage?
    private var avatarBlur: UIImage?
    private var background: UIImage?
    private var backgroundBlur: UIImage?
    private var localImage: UIImage?
    private var localImageExpected = false
    private var localFraming = CallFraming()
    private var backgroundPlayer: AVQueuePlayer?
    private var backgroundLooper: AVPlayerLooper?
    private var backgroundPrepared: PreparedWorkVideo?
    private var backgroundTransform = CGAffineTransform.identity
    private var backgroundShouldPlay = false
    private var backgroundFailed = false
    private var backgroundPreparing = false
    private var generation = UUID()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let outwardRenderer = CallImageOutwardRenderer()
    private var spatialRenderer: CallSpatialRenderer?
    private let spatialMotionID = UUID()
    private var spatialMotionAllowed = true
    var onSpatialFrame: (() -> Void)?

    func setSpatialActive(_ active: Bool) {
        spatialMotionAllowed = active
        if !active { CallSpatialMotion.shared.release(spatialMotionID) }
    }
    private let formalCapture = VideoCapture()
    private let backgroundCapture = VideoCapture()
    private var lastFrame: UIImage?
    private var lastVideoMode: Bool?
    private var outgoingFrame: UIImage?
    private var transitionRequestedAt: TimeInterval = 0
    private var transitionStartedAt: TimeInterval?
    var isTransitioning: Bool { outgoingFrame != nil }
    func hasSettledVideoMode(_ video: Bool) -> Bool { lastVideoMode == video && !isTransitioning }

    @MainActor private final class VideoCapture {
        var item: AVPlayerItem?
        var output: AVPlayerItemVideoOutput?
        var transform = CGAffineTransform.identity
        var orientationReady = false
        var failed = false
        var image: UIImage?
        var blur: UIImage?
        var generation = UUID()
        var preparationTask: Task<Void, Never>?

        func clear() {
            generation = UUID()
            preparationTask?.cancel(); preparationTask = nil
            if let output { item?.remove(output) }
            item = nil; output = nil; image = nil; blur = nil
            orientationReady = false; failed = false
        }

        func markFailed() {
            preparationTask?.cancel(); preparationTask = nil
            image = nil; blur = nil; failed = true
        }
    }

    func prepare(appearance: ResolvedCallAppearance, localImageURL: URL?, localFraming: CallFraming) async {
        stop()
        let expected = generation
        self.appearance = appearance
        self.localFraming = localFraming
        self.localFraming.fillMode = .black
        localImageExpected = localImageURL != nil
        var issues: [String] = []
        if let url = appearance.avatarURL {
            avatar = loadImage(url)
            if avatar == nil { issues.append(InterfaceLocalization.text("通话头像暂不可读取")) }
            if appearance.avatarFraming.fillMode == .blur { avatarBlur = avatar.flatMap(blurred) }
        }
        if let localImageURL {
            localImage = loadImage(localImageURL)
            if localImage == nil { issues.append(InterfaceLocalization.text("我的头像暂不可读取")) }
        }
        if let url = appearance.backgroundURL, appearance.backgroundKind == .image {
            background = loadImage(url)
            if background == nil { issues.append(InterfaceLocalization.text("通话背景图片暂不可读取")) }
            if appearance.backgroundFraming.fillMode == .blur { backgroundBlur = background.flatMap(blurred) }
            if appearance.backgroundFraming.spatialEffectEnabled == true {
                do {
                    let asset = try await CallSpatialDepth.shared.prepare(url: url)
                    try Task.checkCancellation()
                    guard generation == expected else { return }
                    spatialRenderer = CallSpatialRenderer(asset: asset)
                    background = UIImage(cgImage: asset.image)
                } catch is CancellationError { return }
                catch {
                    guard generation == expected else { return }
                    issues.append(InterfaceLocalization.text("空间效果暂不可用，已保留原画"))
                }
            }
        }
        guard generation == expected else { return }
        preparationError = issues.isEmpty ? nil : issues.joined(separator: "；")
        do {
            try Task.checkCancellation()
            guard let url = appearance.backgroundURL, appearance.backgroundKind == .video else { return }
            backgroundPreparing = true
            defer { if generation == expected { backgroundPreparing = false } }
            let playable = try await PreparedWorkVideo.prepare(url)
            try Task.checkCancellation()
            let asset = AVURLAsset(url: playable.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw RenderError.noVideo
            }
            let range = try await source.load(.timeRange)
            let transform = try await source.load(.preferredTransform)
            guard range.duration.isNumeric, range.duration.seconds > 0 else { throw RenderError.noVideo }
            let composition = AVMutableComposition()
            guard let track = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw RenderError.noVideo
            }
            try track.insertTimeRange(range, of: source, at: .zero)
            track.preferredTransform = transform
            try Task.checkCancellation()
            guard generation == expected else { return }
            let queue = AVQueuePlayer()
            queue.isMuted = true; queue.volume = 0
            queue.preventsDisplaySleepDuringVideoPlayback = false
            queue.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            backgroundPrepared = playable
            backgroundTransform = transform
            backgroundLooper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: composition))
            backgroundPlayer = queue
            // A configured frame provider may already have requested video while prepare() was suspended.
            // Honor that current request when the queue finally exists; there may be no later mode change.
            if backgroundShouldPlay { queue.play() }
        } catch is CancellationError {
            if generation == expected { stop() }
        } catch {
            guard generation == expected else { return }
            backgroundFailed = true
            issues.append(InterfaceLocalization.text("通话背景视频暂不可读取"))
            preparationError = issues.joined(separator: "；")
        }
    }

    func frame(useVideo: Bool, formalPlayer: AVPlayer?, videoScale: CGFloat,
               showsLocalImage: Bool, size: CGSize, includesOverlays: Bool = true,
               localPosition: CGPoint = CGPoint(x: 0.8, y: 0.2),
               animatesModeChanges: Bool = false, timestamp: TimeInterval = CACurrentMediaTime()) -> UIImage {
        let size = validSize(size)
        let bounds = CGRect(origin: .zero, size: size)
        let useFormal = useVideo && appearance?.prefersWorkVideo == true && formalPlayer != nil
        let useBackgroundVideo = useVideo && !useFormal && appearance?.backgroundURL != nil
            && appearance?.backgroundKind == .video
        if useVideo && !useFormal && !useBackgroundVideo && spatialRenderer != nil && spatialMotionAllowed {
            CallSpatialMotion.shared.observe(spatialMotionID) { [weak self] in self?.onSpatialFrame?() }
        } else { CallSpatialMotion.shared.release(spatialMotionID) }
        if useBackgroundVideo != backgroundShouldPlay {
            backgroundShouldPlay = useBackgroundVideo
            if useBackgroundVideo && !backgroundFailed { backgroundPlayer?.play() }
            else { backgroundPlayer?.pause() }
        }
        var remoteImage: UIImage?
        var remoteBlur: UIImage?
        var remoteFraming = CallFraming()
        var unavailable: String?
        if useFormal, let formalPlayer {
            attach(formalPlayer.currentItem, to: formalCapture)
            if formalPlayer.status == .failed || formalPlayer.currentItem?.status == .failed {
                formalCapture.markFailed()
            } else {
                remoteImage = capture(formalPlayer, from: formalCapture, makeBlur: false)
            }
            remoteFraming.zoom = Double(videoScale.isFinite ? min(4, max(1, videoScale)) : 1)
            if remoteImage == nil {
                unavailable = formalCapture.failed || formalPlayer.currentItem?.status == .failed
                    ? InterfaceLocalization.text("作品视频暂不可用") : InterfaceLocalization.text("正在准备视频画面…")
            }
        } else {
            if formalCapture.item != nil { formalCapture.clear() }
            if useBackgroundVideo {
                if backgroundFailed || backgroundLooper?.status == .failed || backgroundPlayer?.status == .failed
                    || backgroundPlayer?.currentItem?.status == .failed {
                    backgroundFailed = true
                    backgroundCapture.markFailed()
                    backgroundPlayer?.pause()
                    unavailable = InterfaceLocalization.text("背景视频暂不可用")
                } else if let backgroundPlayer {
                    attach(backgroundPlayer.currentItem, to: backgroundCapture, knownTransform: backgroundTransform)
                    remoteImage = capture(backgroundPlayer, from: backgroundCapture,
                                          makeBlur: appearance?.backgroundFraming.fillMode == .blur)
                    remoteBlur = backgroundCapture.blur
                    if remoteImage == nil {
                        if backgroundCapture.failed { backgroundFailed = true; backgroundPlayer.pause() }
                        unavailable = backgroundCapture.failed ? InterfaceLocalization.text("背景视频暂不可用") : InterfaceLocalization.text("正在准备背景画面…")
                    }
                } else {
                    unavailable = backgroundPreparing ? InterfaceLocalization.text("正在准备背景画面…") : InterfaceLocalization.text("背景视频暂不可用")
                }
            } else if useVideo, appearance?.backgroundURL != nil {
                remoteImage = background; remoteBlur = backgroundBlur
                if remoteImage == nil { unavailable = InterfaceLocalization.text("背景文件暂不可用") }
            }
            remoteFraming = appearance?.backgroundFraming ?? CallFraming()
        }
        frameStatusMessage = useVideo ? unavailable : (appearance?.avatarURL != nil && avatar == nil ? InterfaceLocalization.text("头像暂不可用") : nil)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let target = UIGraphicsImageRenderer(size: size, format: format).image { output in
            UIColor.black.setFill(); output.fill(bounds)
            if useVideo {
                if let remoteImage {
                    draw(remoteImage, blur: remoteBlur, framing: remoteFraming, defaultContentMode: .fill,
                         enhancesImageEdges: !useFormal && !useBackgroundVideo,
                         in: bounds, context: output.cgContext)
                } else if let unavailable {
                    drawPlaceholder(unavailable, in: bounds, scale: displayScale(size))
                }
            } else {
                // Inline controls occupy the lower area. The system floating window
                // has no app controls, so its avatar keeps the centered composition.
                let floatingSide = min(size.width * 0.6, size.height * 0.45)
                let avatarRect = includesOverlays
                    ? CGRect(x: (size.width - floatingSide) / 2, y: (size.height - floatingSide) / 2,
                             width: floatingSide, height: floatingSide)
                    : CallScreenLayout.avatarRect(in: size)
                if let avatar {
                    output.cgContext.saveGState()
                    UIBezierPath(roundedRect: avatarRect, cornerRadius: avatarRect.width * 0.09).addClip()
                    draw(avatar, blur: avatarBlur, framing: appearance?.avatarFraming ?? CallFraming(),
                         in: avatarRect, context: output.cgContext)
                    output.cgContext.restoreGState()
                } else {
                    drawPlaceholder(appearance?.avatarURL == nil ? nil : InterfaceLocalization.text("头像暂不可用"),
                                    in: avatarRect, scale: displayScale(size))
                }
            }
            if includesOverlays {
                drawName(in: bounds)
                if showsLocalImage { drawLocalWindow(in: bounds, position: localPosition, context: output.cgContext) }
            }
        }
        if animatesModeChanges, let mode = lastVideoMode, mode != useVideo,
           let previous = lastFrame, previous.size == size {
            outgoingFrame = previous
            transitionRequestedAt = timestamp; transitionStartedAt = nil
        }
        lastVideoMode = useVideo
        var result = target
        if animatesModeChanges, let outgoingFrame {
            // Keep the actually displayed frame until the incoming video has a
            // frame. A failed video eventually reveals its normal error state.
            if transitionStartedAt == nil,
               !useVideo || remoteImage != nil || timestamp - transitionRequestedAt >= 1.5 {
                transitionStartedAt = timestamp
            }
            let progress = min(1, max(0, (timestamp - (transitionStartedAt ?? timestamp)) / 0.42))
            let eased = progress * progress * (3 - 2 * progress)
            result = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                outgoingFrame.draw(in: bounds)
                target.draw(in: bounds, blendMode: .normal, alpha: eased)
            }
            if progress >= 1 { self.outgoingFrame = nil }
        } else { outgoingFrame = nil }
        lastFrame = result
        return result
    }

    func stop() {
        spatialRenderer = nil; CallSpatialMotion.shared.release(spatialMotionID)
        outwardRenderer.reset()
        lastFrame = nil; lastVideoMode = nil; outgoingFrame = nil; transitionStartedAt = nil
        generation = UUID()
        formalCapture.clear(); backgroundCapture.clear()
        backgroundPlayer?.pause()
        backgroundLooper?.disableLooping(); backgroundLooper = nil
        backgroundPlayer?.removeAllItems(); backgroundPlayer = nil
        backgroundPrepared = nil
        backgroundShouldPlay = false; backgroundFailed = false; backgroundPreparing = false
        appearance = nil; avatar = nil; avatarBlur = nil; background = nil; backgroundBlur = nil
        localImage = nil; localImageExpected = false; preparationError = nil; frameStatusMessage = nil
    }

    private func attach(_ item: AVPlayerItem?, to capture: VideoCapture, knownTransform: CGAffineTransform? = nil) {
        guard capture.item !== item else { return }
        capture.clear()
        guard let item else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        // Leave normal AVPlayerLayer rendering enabled for the app's formal-video page.
        output.suppressesPlayerRendering = false
        item.add(output)
        capture.item = item; capture.output = output
        if let knownTransform {
            capture.transform = knownTransform; capture.orientationReady = true
            return
        }
        let rendererGeneration = generation, captureGeneration = capture.generation
        capture.preparationTask = Task { [weak self, weak capture] in
            do {
                guard let track = try await item.asset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideo }
                let transform = try await track.load(.preferredTransform)
                try Task.checkCancellation()
                guard let self, let capture, self.generation == rendererGeneration,
                      capture.generation == captureGeneration, capture.item === item else { return }
                capture.transform = transform; capture.orientationReady = true
                capture.preparationTask = nil
            } catch {
                guard !Task.isCancelled, let self, let capture, self.generation == rendererGeneration,
                      capture.generation == captureGeneration else { return }
                capture.failed = true; capture.preparationTask = nil
            }
        }
    }

    private func capture(_ player: AVPlayer, from capture: VideoCapture, makeBlur: Bool) -> UIImage? {
        if capture.failed || capture.item?.status == .failed {
            capture.markFailed(); return nil
        }
        guard capture.orientationReady, let output = capture.output else { return capture.image }
        let time = player.currentTime()
        guard time.isNumeric else { return capture.image }
        if output.hasNewPixelBuffer(forItemTime: time) || capture.image == nil,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            var image = CIImage(cvPixelBuffer: buffer)
            // Track transforms use top-left coordinates. Convert into/out of that system before
            // applying them to Core Image's bottom-left coordinates, then normalize the extent.
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                            tx: 0, ty: image.extent.height))
                .transformed(by: capture.transform)
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            let extent = image.extent
            guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
                capture.markFailed(); return nil
            }
            // A decoded 4K source should not allocate a full-resolution CGImage for every small PiP frame.
            let downsample = min(1, 1440 / max(extent.width, extent.height))
            if downsample < 1 { image = image.transformed(by: CGAffineTransform(scaleX: downsample, y: downsample)) }
            if let rendered = context.createCGImage(image, from: image.extent) {
                let frame = UIImage(cgImage: rendered)
                capture.image = frame
                capture.blur = makeBlur ? blurred(frame) : nil
            }
        }
        return capture.image
    }

    private func loadImage(_ url: URL) -> UIImage? {
        guard url.isFileURL else { return nil }
        let original = WorkAssetImporter.originalImageForCropping(at: url.path)
        guard let source = CGImageSourceCreateWithURL(original as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1440,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func blurred(_ image: UIImage) -> UIImage? {
        guard let source = CIImage(image: image) else { return nil }
        let factor = min(1, 512 / max(source.extent.width, source.extent.height))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let result = scaled.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18])
            .cropped(to: scaled.extent)
        return context.createCGImage(result, from: scaled.extent).map { UIImage(cgImage: $0) }
    }

    private func draw(_ image: UIImage, blur: UIImage?, framing: CallFraming,
                      defaultContentMode: CallFramingContentMode = .fit,
                      enhancesImageEdges: Bool = false,
                      in bounds: CGRect, context: CGContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        context.saveGState(); context.clip(to: bounds)
        if framing.fillMode == .blur, let blur {
            let fill = max(bounds.width / blur.size.width, bounds.height / blur.size.height)
            blur.draw(in: CGRect(x: bounds.midX - blur.size.width * fill / 2,
                                 y: bounds.midY - blur.size.height * fill / 2,
                                 width: blur.size.width * fill, height: blur.size.height * fill))
            UIColor.black.withAlphaComponent(0.18).setFill(); UIBezierPath(rect: bounds).fill()
        }
        let zoom = framing.zoom.isFinite ? min(5, max(0.25, framing.zoom)) : 1
        let offsetX = framing.offsetX.isFinite ? min(1, max(-1, framing.offsetX)) : 0
        let offsetY = framing.offsetY.isFinite ? min(1, max(-1, framing.offsetY)) : 0
        let horizontal = bounds.width / image.size.width
        let vertical = bounds.height / image.size.height
        let fit = ((framing.contentMode ?? defaultContentMode) == .fill
            ? max(horizontal, vertical) : min(horizontal, vertical)) * zoom
        let rect = CGRect(x: bounds.midX - image.size.width * fit / 2 + bounds.width * offsetX / 2,
                          y: bounds.midY - image.size.height * fit / 2 + bounds.height * offsetY / 2,
                          width: image.size.width * fit, height: image.size.height * fit)
        if defaultContentMode == .fill {
            if enhancesImageEdges, framing.spatialEffectEnabled == true, let spatialRenderer,
               let rendered = spatialRenderer.image(pose: CallSpatialMotion.shared.pose, rect: rect, viewport: bounds) {
                rendered.draw(in: bounds)
            } else if enhancesImageEdges,
               let rendered = outwardRenderer.render(image, in: rect, viewport: bounds) {
                rendered.draw(in: bounds)
            } else {
                CallImageEdgeBlend.draw(image, in: rect, viewport: bounds, context: context)
            }
        } else { image.draw(in: rect) }
        context.restoreGState()
    }

    private func drawPlaceholder(_ text: String?, in rect: CGRect, scale: CGFloat) {
        let side = min(rect.width * 0.55, rect.height * 0.55)
        let icon = UIImage(systemName: "person.crop.circle",
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: side, weight: .regular))?
            .withTintColor(.white.withAlphaComponent(0.65), renderingMode: .alwaysOriginal)
        icon?.draw(in: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2 - (text == nil ? 0 : 12 * scale),
                              width: side, height: side))
        if let text {
            drawText(text, in: CGRect(x: rect.minX + 8 * scale, y: rect.midY + side / 2,
                                     width: max(1, rect.width - 16 * scale), height: 55 * scale),
                     font: .systemFont(ofSize: 13 * scale), color: .white)
        }
    }

    private func drawName(in rect: CGRect) {
        let scale = displayScale(rect.size)
        let name = appearance?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let area = CGRect(x: 12 * scale, y: 14 * scale, width: max(1, rect.width - 24 * scale), height: 70 * scale)
        UIColor.black.withAlphaComponent(0.6).setFill()
        UIBezierPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: area.maxY + 8 * scale)).fill()
        drawText(name.isEmpty ? InterfaceLocalization.text("通话") : name, in: area, font: .systemFont(ofSize: 22 * scale, weight: .semibold), color: .white)
    }

    private func drawLocalWindow(in bounds: CGRect, position: CGPoint, context: CGContext) {
        let scale = displayScale(bounds.size)
        let width = min(bounds.width * 0.28, 118 * scale)
        let height = min(width * 4 / 3, bounds.height - 16 * scale)
        let x = position.x.isFinite ? min(1, max(0, position.x)) * bounds.width : bounds.width * 0.8
        let y = position.y.isFinite ? min(1, max(0, position.y)) * bounds.height : bounds.height * 0.2
        let rect = CGRect(x: min(max(8 * scale, x - width / 2), bounds.width - width - 8 * scale),
                          y: min(max(8 * scale, y - height / 2), bounds.height - height - 8 * scale),
                          width: width, height: max(1, height))
        context.saveGState()
        let shape = UIBezierPath(roundedRect: rect, cornerRadius: 12 * scale)
        shape.addClip(); UIColor.black.setFill(); shape.fill()
        let imageRect = rect
        if let localImage { draw(localImage, blur: nil, framing: localFraming, in: imageRect, context: context) }
        else {
            drawPlaceholder(localImageExpected ? InterfaceLocalization.text("图片暂不可用") : InterfaceLocalization.text("请先在设置中选择图片"), in: imageRect, scale: scale * 0.75)
        }
        context.restoreGState()
        UIColor.white.withAlphaComponent(0.5).setStroke(); shape.lineWidth = scale; shape.stroke()
    }

    private func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center; style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func displayScale(_ size: CGSize) -> CGFloat { max(0.25, min(size.width / 390, size.height / 844)) }

    private func validSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return CGSize(width: 720, height: 960)
        }
        let factor = min(1, 1920 / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
    }

    private enum RenderError: Error { case noVideo }
}
