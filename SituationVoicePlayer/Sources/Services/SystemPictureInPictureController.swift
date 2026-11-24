import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

/// System PiP for rendered local-media content. This deliberately does not use
/// AVKit's active-video-call content source or create another audio session.
@MainActor
final class SystemPictureInPictureController: NSObject, ObservableObject {
    enum Kind { case call, subtitles }

    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var renderSize = CGSize(width: 640, height: 360)
    var configuredKind: Kind? { session?.kind }
    var requiresReconfiguration: Bool { session?.failedStart == true || session?.programmaticStop == true }

    /// The caller enables this only for a connected call. Subtitle PiP always
    /// stays manual, even if a caller accidentally sets this property to true.
    var automaticEnabled = false {
        didSet { updateAutomaticStart() }
    }

    fileprivate let displayLayer = AVSampleBufferDisplayLayer()
    private var session: Session?
    private var possibleObservation: NSKeyValueObservation?
    private var frameTimer: Timer?
    private var timebase: CMTimebase?
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var bufferWidth = 0
    private var bufferHeight = 0
    private nonisolated let playbackSnapshot = PlaybackSnapshot()
    private nonisolated let playbackCommands = AudioRemoteCommandGate()

    /// AVKit's synchronous playback queries need an answer even if delivered
    /// off-main. Keep just these immutable-identity/value reads behind a lock.
    private final class PlaybackSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var controllerID: ObjectIdentifier?
        private var paused = true

        func update(controllerID: ObjectIdentifier?, paused: Bool) {
            lock.lock(); defer { lock.unlock() }
            self.controllerID = controllerID; self.paused = paused
        }

        func read(for id: ObjectIdentifier) -> (matches: Bool, paused: Bool) {
            lock.lock(); defer { lock.unlock() }
            return (controllerID == id, controllerID == id ? paused : true)
        }
    }

    private final class Session {
        let id = UUID()
        let kind: Kind
        let controller: AVPictureInPictureController
        let frameProvider: () -> UIImage?
        let onPlayback: (Bool) -> Void
        let onRestore: (@escaping (Bool) -> Void) -> Void
        let onExternalStop: () -> Void
        var starting = false
        var everStarted = false
        var failedStart = false
        var programmaticStop = false
        var returningInline = false
        var restoring = false
        var restorationSucceeded = false
        var presentationID = UUID()
        var pendingRestoration: RestorationRequest?
        var clearAfterStop = false
        var inputPaused = false
        var subtitleFrozen = false
        var externalStopDelivered = false

        init(kind: Kind, controller: AVPictureInPictureController,
             frameProvider: @escaping () -> UIImage?, onPlayback: @escaping (Bool) -> Void,
             onRestore: @escaping (@escaping (Bool) -> Void) -> Void,
             onExternalStop: @escaping () -> Void) {
            self.kind = kind
            self.controller = controller
            self.frameProvider = frameProvider
            self.onPlayback = onPlayback
            self.onRestore = onRestore
            self.onExternalStop = onExternalStop
        }
    }

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        var created: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &created) == noErr, let created {
            timebase = created
            CMTimebaseSetTime(created, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(created, rate: 1)
            displayLayer.controlTimebase = created
        }
    }

    /// Configuration is a new session, not an in-place switch between the two
    /// user-facing features. Providers may read changing state from their owner.
    @discardableResult
    func configure(kind: Kind, framesPerSecond: Double = 10,
                   frameProvider: @escaping () -> UIImage?,
                   onPlayback: @escaping (Bool) -> Void,
                   onRestore: @escaping (@escaping (Bool) -> Void) -> Void,
                   onExternalStop: @escaping () -> Void) -> Bool {
        guard !isActive, !isStopping, session?.starting != true else { return false }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            errorMessage = InterfaceLocalization.text("此设备暂不支持系统画中画。")
            return false
        }
        guard timebase != nil else {
            errorMessage = InterfaceLocalization.text("无法准备画中画显示时钟。")
            return false
        }
        discardConfiguration()
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        let configured = Session(kind: kind, controller: controller, frameProvider: frameProvider,
            onPlayback: onPlayback, onRestore: onRestore, onExternalStop: onExternalStop)
        session = configured
        playbackCommands.transition(allowsAudio: true)
        playbackSnapshot.update(controllerID: ObjectIdentifier(controller), paused: false)
        isPaused = false
        errorMessage = nil
        controller.invalidatePlaybackState()
        let expected = configured.id
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) {
            [weak self] _, _ in
            Task { @MainActor in
                guard let self, let session = self.session, session.id == expected else { return }
                self.isPossible = session.controller.isPictureInPicturePossible
            }
        }
        updateAutomaticStart()
        let fps = framesPerSecond.isFinite ? min(30, max(1, framesPerSecond)) : 10
        let timer = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session?.id == expected else { return }
                self.enqueueFrame(force: false)
            }
        }
        timer.tolerance = min(0.02, 0.1 / fps)
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        enqueueFrame(force: true)
        return true
    }

    /// Manual start only. Automatic call PiP uses AVKit's inline preference;
    /// this method never schedules retries or starts after a failed attempt.
    @discardableResult
    func start() -> Bool {
        guard let session, !isActive, !isStopping, !session.starting,
              !session.failedStart, !session.programmaticStop, !session.returningInline else { return false }
        enqueueFrame(force: true)
        guard session.controller.isPictureInPicturePossible else {
            errorMessage = InterfaceLocalization.text("画中画暂不可用，请在画面准备好后重试。")
            return false
        }
        errorMessage = nil
        preparePresentation(session)
        session.starting = true
        isStarting = true
        session.controller.startPictureInPicture()
        return true
    }

    /// The visible call page is taking presentation back, while keeping the same media and PiP session.
    /// A real system restore callback owns its own completion and must not be interrupted here.
    func returnToInline() {
        guard let session, session.kind == .call, !session.restoring,
              !session.programmaticStop, !session.clearAfterStop, !session.failedStart,
              !session.returningInline, !isStopping,
              isActive || session.starting || session.controller.isPictureInPictureActive else { return }
        session.returningInline = true
        updateAutomaticStart()
        isStopping = true
        session.controller.stopPictureInPicture()
    }

    /// Call before asking AVKit to stop. Its delegate supplies no stop reason,
    /// so this explicit intent distinguishes our own stop from an external one.
    func stopProgrammatically() {
        automaticEnabled = false
        guard let session else { return }
        session.programmaticStop = true
        session.returningInline = false
        let restoration = session.pendingRestoration
        session.pendingRestoration = nil
        restoration?.finish(false)
        guard self.session?.id == session.id else { return }
        if isActive || session.starting || isStopping || session.controller.isPictureInPictureActive {
            isStopping = true
            session.controller.stopPictureInPicture()
        }
    }

    /// Safe when called during start/restore/stop: keep the old session alive
    /// until its callbacks finish, and ignore callbacks from earlier controllers.
    func clearConfiguration() {
        guard let session else { discardConfiguration(); return }
        session.clearAfterStop = true
        stopProgrammatically()
        if !isActive, !isStopping, !session.starting { discardConfiguration() }
    }

    /// The app's media state is input only. Subtitle PiP's Play/Pause affects
    /// its rendered frames, never the app's audio playback or listening clock.
    func setPlaybackPaused(_ paused: Bool) {
        guard let session else { return }
        session.inputPaused = paused
        updatePausedState()
    }

    /// Reject delegate work captured before a newer pause, route change or
    /// interruption boundary. The next genuinely new PiP control remains usable.
    func invalidatePendingPlaybackCommands() {
        playbackCommands.transition(allowsAudio: session != nil)
    }

    /// Refresh a static image after an appearance change, including while paused.
    func refreshFrame() { enqueueFrame(force: true) }

    private func updatePausedState() {
        guard let session else { isPaused = false; return }
        let paused = session.inputPaused || (session.kind == .subtitles && session.subtitleFrozen)
        guard isPaused != paused else { return }
        invalidatePendingPlaybackCommands()
        isPaused = paused
        playbackSnapshot.update(controllerID: ObjectIdentifier(session.controller), paused: paused)
        session.controller.invalidatePlaybackState()
        if !paused { enqueueFrame(force: true) }
    }

    private func updateAutomaticStart() {
        guard let session else { return }
        session.controller.canStartPictureInPictureAutomaticallyFromInline = automaticEnabled
            && session.kind == .call && !session.failedStart && !session.programmaticStop && !session.returningInline
    }

    private func matchingSession(_ identity: ObjectIdentifier) -> Session? {
        guard let session, ObjectIdentifier(session.controller) == identity else { return nil }
        return session
    }

    private func preparePresentation(_ session: Session) {
        // An automatic start notification may arrive after the visible page has
        // already requested inline return. Keep that intent until a terminal callback.
        guard !session.returningInline else { return }
        session.presentationID = UUID()
        session.everStarted = false
        session.restoring = false
        session.restorationSucceeded = false
        session.externalStopDelivered = false
    }

    private nonisolated func onMain(_ action: @escaping @MainActor @Sendable (SystemPictureInPictureController) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action(self) }
        } else {
            // Retain through delivery so callbacks with completion handlers
            // are not silently lost while the owner is being torn down.
            Task { @MainActor in action(self) }
        }
    }

    private func discardConfiguration() {
        playbackCommands.transition(allowsAudio: false)
        frameTimer?.invalidate(); frameTimer = nil
        possibleObservation?.invalidate(); possibleObservation = nil
        if let session {
            session.controller.canStartPictureInPictureAutomaticallyFromInline = false
            session.controller.delegate = nil
            session.controller.contentSource = nil
            let restoration = session.pendingRestoration
            session.pendingRestoration = nil
            restoration?.finish(false)
        }
        session = nil
        playbackSnapshot.update(controllerID: nil, paused: true)
        isActive = false; isPossible = false; isStarting = false; isStopping = false; isPaused = false
        pixelBufferPool = nil; formatDescription = nil
        bufferWidth = 0; bufferHeight = 0
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func enqueueFrame(force: Bool) {
        guard let session, force || !isPaused, !isStopping else { return }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        guard let image = session.frameProvider() else { return }
        do {
            let buffer = try makeSampleBuffer(image)
            renderer.enqueue(buffer)
        } catch {
            errorMessage = InterfaceLocalization.text("无法更新画中画画面：\(error.localizedDescription)")
        }
    }

    private func makeSampleBuffer(_ image: UIImage) throws -> CMSampleBuffer {
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw FrameError.invalidImage
        }
        // Bound memory even if a provider inadvertently returns an original photo.
        let scale = min(1, 1280 / max(width, height))
        let pixelWidth = max(2, Int(width * scale) / 2 * 2)
        let pixelHeight = max(2, Int(height * scale) / 2 * 2)
        if pixelBufferPool == nil || pixelWidth != bufferWidth || pixelHeight != bufferHeight {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: pixelWidth, kCVPixelBufferHeightKey: pixelHeight,
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool else { throw FrameError.bufferCreation }
            pixelBufferPool = pool; formatDescription = nil
            bufferWidth = pixelWidth; bufferHeight = pixelHeight
        }
        guard let pool = pixelBufferPool else { throw FrameError.bufferCreation }
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created) == kCVReturnSuccess,
              let pixelBuffer = created else { throw FrameError.bufferCreation }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { throw FrameError.bufferCreation }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bitmap = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: pixelWidth,
            height: pixelHeight, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { throw FrameError.bufferCreation }
        let bounds = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        context.setFillColor(UIColor.black.cgColor); context.fill(bounds)
        context.translateBy(x: 0, y: CGFloat(pixelHeight)); context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        image.draw(in: bounds)
        UIGraphicsPopContext()
        if formatDescription == nil {
            var format: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr else { throw FrameError.bufferCreation }
            formatDescription = format
        }
        guard let formatDescription else { throw FrameError.bufferCreation }
        // The visual live timeline uses host time. Pausing freezes frame production;
        // the independent media player remains the sole source of audio position.
        let now = timebase.map(CMTimebaseGetTime) ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw FrameError.bufferCreation }
        return sample
    }

    private enum FrameError: LocalizedError {
        case invalidImage, bufferCreation
        var errorDescription: String? { InterfaceLocalization.text("无法准备显示帧。") }
    }

    deinit {
        frameTimer?.invalidate()
        possibleObservation?.invalidate()
    }
}

extension SystemPictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let identity = ObjectIdentifier(controller)
        onMain { owner in
            guard let session = owner.matchingSession(identity) else { return }
            if !session.starting, !owner.isActive, !owner.isStopping { owner.preparePresentation(session) }
            session.starting = true
            owner.isStarting = true
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let identity = ObjectIdentifier(controller)
        onMain { owner in
            guard let session = owner.matchingSession(identity) else { return }
            session.starting = false; session.everStarted = true
            owner.isActive = true
            owner.isStarting = false
            if session.programmaticStop || session.returningInline {
                owner.isStopping = true
                session.controller.stopPictureInPicture()
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        let identity = ObjectIdentifier(controller), message = error.localizedDescription
        onMain { owner in
            guard let session = owner.matchingSession(identity) else { return }
            let returnedInline = session.returningInline && !session.programmaticStop && !session.clearAfterStop
            session.starting = false
            session.everStarted = false
            session.returningInline = false
            // Cancelling an in-flight start to return inline must not poison the next automatic start.
            session.failedStart = !returnedInline
            let restoration = session.pendingRestoration
            session.pendingRestoration = nil
            restoration?.finish(false)
            owner.isActive = false; owner.isStarting = false; owner.isStopping = false
            owner.errorMessage = returnedInline ? nil : InterfaceLocalization.text("系统画中画未能开启：\(message)")
            owner.updateAutomaticStart()
            // A failed start is never treated as a user closing the window.
            if session.clearAfterStop { owner.discardConfiguration() }
            else if returnedInline { owner.enqueueFrame(force: true) }
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let identity = ObjectIdentifier(controller)
        onMain { owner in
            guard owner.matchingSession(identity) != nil else { return }
            owner.isStopping = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let identity = ObjectIdentifier(controller)
        onMain { owner in
            guard let stopped = owner.matchingSession(identity) else { return }
            stopped.starting = false
            let returnedInline = stopped.returningInline
            stopped.returningInline = false
            // The public API does not distinguish user dismissal from system stop.
            // The caller explicitly chooses the external-stop policy for each kind.
            let external = stopped.everStarted && !stopped.programmaticStop && !returnedInline && !stopped.restorationSucceeded
                && !stopped.failedStart && !stopped.externalStopDelivered
            // A duplicate stop callback cannot dismiss a presentation that has already ended.
            stopped.everStarted = false
            stopped.externalStopDelivered = external || stopped.externalStopDelivered
            let restoration = stopped.pendingRestoration
            stopped.pendingRestoration = nil
            restoration?.finish(false)
            if external { owner.automaticEnabled = false }
            else if returnedInline || stopped.restorationSucceeded { owner.updateAutomaticStart() }
            if stopped.clearAfterStop { owner.discardConfiguration() }
            else {
                owner.isActive = false; owner.isStarting = false; owner.isStopping = false
                if returnedInline { owner.enqueueFrame(force: true) }
            }
            if external { stopped.onExternalStop() }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        let identity = ObjectIdentifier(controller)
        onMain { owner in
            guard let session = owner.matchingSession(identity), !session.programmaticStop,
                  !session.clearAfterStop, !session.failedStart else { completionHandler(false); return }
            // System restoration and an already accepted inline return are
            // independent reasons for this presentation to stop without hanging up.
            session.restoring = true
            let expected = session.id, presentation = session.presentationID
            let previousRequest = session.pendingRestoration
            let request = RestorationRequest(completionHandler)
            session.pendingRestoration = request
            previousRequest?.finish(false)
            // Finishing the previous system request may synchronously stop or
            // clear this session. Do not start app restoration after that point.
            guard owner.session?.id == expected, session.presentationID == presentation,
                  session.pendingRestoration === request, !session.programmaticStop,
                  !session.clearAfterStop, !session.failedStart else { request.finish(false); return }
            session.onRestore { [weak owner] restored in
                guard let owner else {
                    Task { @MainActor in request.finish(false) }
                    return
                }
                // A synchronous successful restore must be recorded before a
                // subsequent didStop callback, without an extra main-queue hop.
                owner.onMain { owner in
                    let current = owner.session
                    let matches = current?.id == expected && current?.presentationID == presentation
                        && current?.pendingRestoration === request
                    if matches {
                        current?.restorationSucceeded = restored
                        current?.pendingRestoration = nil
                    }
                    // A superseded or already cancelled request cannot change
                    // this presentation's result, but still completes at most once.
                    request.finish(matches && restored)
                }
            }
        }
    }

    @MainActor private final class RestorationRequest {
        private var completed = false
        private let completion: @Sendable (Bool) -> Void

        init(_ completion: @escaping @Sendable (Bool) -> Void) { self.completion = completion }

        func finish(_ restored: Bool) {
            guard !completed else { return }
            completed = true
            completion(restored)
        }
    }
}

extension SystemPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        let identity = ObjectIdentifier(controller)
        let ticket = playbackCommands.capture()
        onMain { owner in
            guard owner.playbackCommands.accepts(ticket),
                  let session = owner.matchingSession(identity), owner.isActive,
                  !session.programmaticStop, !session.returningInline, !session.restoring, !session.failedStart,
                  !session.externalStopDelivered, !owner.isStopping else { return }
            if session.kind == .subtitles {
                session.subtitleFrozen = !playing
                owner.updatePausedState()
            } else {
                session.onPlayback(playing)
            }
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        guard playbackSnapshot.read(for: ObjectIdentifier(controller)).matches else { return .invalid }
        return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        playbackSnapshot.read(for: ObjectIdentifier(controller)).paused
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        let identity = ObjectIdentifier(controller)
        guard newRenderSize.width > 0, newRenderSize.height > 0 else { return }
        let size = CGSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        onMain { owner in
            guard owner.matchingSession(identity) != nil else { return }
            owner.renderSize = size
            owner.enqueueFrame(force: true)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                   completion completionHandler: @escaping @Sendable () -> Void) {
        // This is a rendered live surface, not a second seekable media player.
        completionHandler()
    }

    nonisolated func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool {
        false
    }
}

/// Install exactly one visible surface for the configured feature. A hidden or
/// detached one-pixel layer is not a substitute for the user's inline content.
struct SystemPictureInPictureSurface: UIViewRepresentable {
    @ObservedObject var controller: SystemPictureInPictureController

    func makeUIView(context: Context) -> SystemPictureInPictureSurfaceView {
        SystemPictureInPictureSurfaceView(displayLayer: controller.displayLayer)
    }

    func updateUIView(_ view: SystemPictureInPictureSurfaceView, context: Context) {
        view.install(controller.displayLayer)
    }
}

final class SystemPictureInPictureSurfaceView: UIView {
    private var displayLayer: AVSampleBufferDisplayLayer?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        install(displayLayer)
    }

    required init?(coder: NSCoder) { nil }

    func install(_ displayLayer: AVSampleBufferDisplayLayer) {
        if self.displayLayer !== displayLayer || displayLayer.superlayer !== layer {
            self.displayLayer?.removeFromSuperlayer()
            self.displayLayer = displayLayer
            layer.addSublayer(displayLayer)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }
}
