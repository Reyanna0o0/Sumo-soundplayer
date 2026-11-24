import SwiftUI
import Combine

/// Owns both independent PiP features beyond the lifetime of a presented player page.
/// Audio, media position and listening statistics remain owned by PlayerController.
@MainActor
final class AppPictureInPictureCoordinator: ObservableObject {
    let pip = SystemPictureInPictureController()
    private let callRenderer = CallPictureInPictureRenderer()
    private let subtitleRenderer = SubtitlePictureInPictureRenderer()
    @Published var isSubtitleSheetPresented = false
    @Published var wantsSubtitlePage = false
    @Published private(set) var message: String?
    @Published private(set) var hasCallSurface = false
    @Published private(set) var subtitleFallbackFrame: UIImage?
    @Published var localPosition = CGPoint(x: 0.8, y: 0.22)
    @Published var subtitleOptions: SubtitlePictureInPicturePreferences {
        didSet {
            if let data = try? JSONEncoder().encode(subtitleOptions) {
                defaults.set(data, forKey: Self.preferencesKey)
            }
            if pip.configuredKind == .subtitles { pip.refreshFrame() }
            else { refreshSubtitleFallback() }
        }
    }
    private static let preferencesKey = "hibiki.subtitle.pictureInPicture"
    private let defaults: UserDefaults
    private weak var player: PlayerController?
    private weak var store: LibraryStore?
    private weak var subtitles: SubtitleController?
    private var subscriptions = Set<AnyCancellable>()
    private var preparation: Task<Void, Never>?
    private var preparationID = UUID()
    private var subtitleStartRequest: Task<Void, Never>?
    private var subtitleStartAttemptID: UUID?
    private var subtitleGeneration = UUID()
    private var preparedWorkID: Int64?
    private var callSize = CGSize(width: 480, height: 800)
    private var callTransitionTask: Task<Void, Never>?
    private var phase: ScenePhase = .active
    private var visiblePages = Set<SystemPictureInPictureController.Kind>()
    private var restoration: (id: UUID, kind: SystemPictureInPictureController.Kind, completion: (Bool) -> Void)?
    private var restoreTimeout: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode(SubtitlePictureInPicturePreferences.self, from: $0) }
        var options = decoded ?? .init()
        options.fontSize = options.fontSize.isFinite ? min(38, max(16, options.fontSize)) : 24
        subtitleOptions = options
    }

    func interfaceLanguageChanged() {
        pip.refreshFrame()
        refreshSubtitleFallback()
    }

    func attach(player: PlayerController, store: LibraryStore, subtitles: SubtitleController) {
        guard self.player !== player else { return }
        subscriptions.removeAll()
        self.player = player; self.store = store; self.subtitles = subtitles
        callRenderer.onSpatialFrame = { [weak self] in
            guard let self, self.phase == .active, self.visiblePages.contains(.call) || self.pip.isActive,
                  self.player?.isInCall == true, self.player?.callUsesVideo == true else { return }
            self.pip.refreshFrame()
        }
        // @Published emits before assignment; defer reads until the new state is installed.
        player.$callPhase.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileCall() }
        }.store(in: &subscriptions)
        player.$currentItem.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSubtitleTrack() }
        }.store(in: &subscriptions)
        player.requestsInvalidateSystemPlayback.sink { [weak self] _ in
            self?.pip.invalidatePendingPlaybackCommands()
        }.store(in: &subscriptions)
        player.requestsStopPictureInPicture.sink { [weak self] _ in
            guard let self else { return }
            self.preparationID = UUID(); self.preparation?.cancel(); self.preparation = nil
            self.subtitleGeneration = UUID()
            self.subtitleStartRequest?.cancel(); self.subtitleStartRequest = nil
            self.cancelRestoration()
            self.pip.clearConfiguration()
            self.callRenderer.stop(); self.hasCallSurface = false; self.preparedWorkID = nil
            self.isSubtitleSheetPresented = false
            self.releaseDisplaySession()
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.returnCallToInlineIfVisible() }
            }.store(in: &subscriptions)
        player.$positionMS.sink { [weak self] position in
            self?.subtitles?.update(positionMS: position)
        }.store(in: &subscriptions)
        subtitles.$currentCue.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSubtitleFallback() }
        }.store(in: &subscriptions)
        player.$isPlaying.sink { [weak self] playing in
            guard let self, self.pip.configuredKind == .call else { return }
            self.pip.setPlaybackPaused(!playing)
        }.store(in: &subscriptions)
        store.$contentRevision.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadCallAppearance()
                self?.refreshSubtitleBackground()
            }
        }.store(in: &subscriptions)
        pip.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.objectWillChange.send()
                self.observePiPState()
            }
        }.store(in: &subscriptions)
        updateSubtitleTrack()
        reconcileCall()
    }

    func sceneChanged(_ phase: ScenePhase) {
        self.phase = phase
        callRenderer.setSpatialActive(phase == .active && (visiblePages.contains(.call) || pip.isActive))
        pip.refreshFrame()
        finishRestorationIfVisible()
        returnCallToInlineIfVisible()
    }

    func pageVisibility(_ kind: SystemPictureInPictureController.Kind, visible: Bool) {
        if visible { visiblePages.insert(kind) } else { visiblePages.remove(kind) }
        callRenderer.setSpatialActive(phase == .active && (visiblePages.contains(.call) || pip.isActive))
        if kind == .call && visible { pip.refreshFrame() }
        finishRestorationIfVisible()
        if kind == .call, visible { returnCallToInlineIfVisible() }
    }

    private func returnCallToInlineIfVisible() {
        guard phase == .active, UIApplication.shared.applicationState == .active,
              visiblePages.contains(.call), player?.isInCall == true,
              pip.configuredKind == .call else { return }
        // Opening the app icon does not ask AVKit's restore delegate. Return to the
        // visible call without hanging up or disabling the next automatic PiP session.
        pip.returnToInline()
    }

    func setCallSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let scale = min(1, 960 / max(size.width, size.height))
        callSize = CGSize(width: size.width * scale, height: size.height * scale)
    }

    func toggleCallVideoPresentation() {
        guard let player, player.callPhase == .connected else { return }
        callTransitionTask?.cancel()
        player.callUsesVideo.toggle()
        // Paused playback normally suspends the PiP frame timer. Decoration
        // transitions still need fresh frames, without changing audio playback.
        callTransitionTask = Task { @MainActor [weak self] in
            for _ in 0..<75 {
                guard let self, !Task.isCancelled, self.player?.isInCall == true else { return }
                self.pip.refreshFrame()
                if self.callRenderer.hasSettledVideoMode(player.callUsesVideo) { return }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    /// A decoration-only frame for an inline mode transition; it does not start or stop PiP.
    func makeInlineCallSnapshot(size: CGSize) -> UIImage? {
        guard let player, player.isInCall, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return callRenderer.frame(useVideo: player.callUsesVideo,
            formalPlayer: player.isVideo ? player.videoPlayer : nil, videoScale: player.videoScale,
            showsLocalImage: player.callShowsLocalImage, size: size,
            includesOverlays: false, localPosition: localPosition)
    }

    private func reconcileCall() {
        guard let player else { return }
        if !player.isInCall {
            callTransitionTask?.cancel(); callTransitionTask = nil
            preparationID = UUID(); preparation?.cancel(); preparation = nil
            preparedWorkID = nil; hasCallSurface = false
            callRenderer.stop()
            if pip.configuredKind == .call {
                pip.clearConfiguration()
                releaseDisplaySession()
            }
            if restoration?.kind == .call { cancelRestoration() }
            return
        }
        isSubtitleSheetPresented = false
        subtitleGeneration = UUID()
        subtitleStartRequest?.cancel(); subtitleStartRequest = nil
        if preparedWorkID != player.callWorkID { reloadCallAppearance() }
        if pip.configuredKind == .call {
            pip.automaticEnabled = player.callPhase == .connected
            pip.setPlaybackPaused(!player.isPlaying)
            if player.callPhase == .connected { _ = acquireDisplaySession() }
        }
    }

    private func reloadCallAppearance() {
        guard let player, player.isInCall, let workID = player.callWorkID, let store else { return }
        preparedWorkID = workID
        preparation?.cancel()
        preparationID = UUID()
        let expected = preparationID
        preparation = Task { [weak self, weak player, weak store] in
            guard let self, let player, let store, !Task.isCancelled,
                  self.preparationID == expected else { return }
            // A subtitle window ends before a call is configured. It never changes into a call window.
            if self.pip.configuredKind != .call || !self.hasCallSurface || self.pip.isStopping {
                guard await self.clearPreviousSession(), !Task.isCancelled,
                      self.preparationID == expected else { return }
            }
            do {
                guard let work = try store.repository?.work(id: workID) else { return }
                let appearance = try store.resolvedCallAppearance(for: work)
                let local = try store.callProfile(ownerKind: .localUser, id: 0)
                let localURL = local.avatarMode == .custom ? store.callAssetURL(local.avatarAssetPath) : nil
                guard !Task.isCancelled, self.preparationID == expected else { return }
                await self.callRenderer.prepare(appearance: appearance, localImageURL: localURL,
                                                localFraming: local.avatarFraming)
                guard !Task.isCancelled, self.preparationID == expected, player.callWorkID == workID,
                      player.isInCall else { return }
                self.message = self.callRenderer.preparationError
                if self.pip.configuredKind != .call {
                    let configured = self.pip.configure(kind: .call, frameProvider: { [weak self] in
                        guard let self, let player = self.player, player.isInCall else { return nil }
                        return self.callRenderer.frame(useVideo: player.callUsesVideo,
                            formalPlayer: player.isVideo ? player.videoPlayer : nil, videoScale: player.videoScale,
                            showsLocalImage: player.callShowsLocalImage, size: self.callSize,
                            includesOverlays: self.pip.isActive || self.phase != .active,
                            localPosition: self.localPosition, animatesModeChanges: true)
                    }, onPlayback: { [weak player] playing in
                        guard let player, player.callPhase == .connected else { return }
                        player.setPictureInPicturePlayback(playing)
                    }, onRestore: { [weak self] completion in
                        guard let self else { completion(false); return }
                        self.restore(.call, completion: completion)
                    }, onExternalStop: { [weak self, weak player] in
                        // User-approved conservative policy: every other stop hangs up.
                        player?.endCall()
                        self?.releaseDisplaySession()
                    })
                    self.hasCallSurface = configured
                    if !configured { self.message = self.pip.errorMessage }
                }
                self.pip.automaticEnabled = player.callPhase == .connected && self.hasCallSurface
                self.pip.setPlaybackPaused(!player.isPlaying)
                if player.callPhase == .connected, self.hasCallSurface { _ = self.acquireDisplaySession() }
                self.pip.refreshFrame()
            } catch {
                guard self.preparationID == expected else { return }
                self.message = InterfaceLocalization.text("无法准备通话浮窗：\(error.localizedDescription)")
            }
        }
    }

    func prepareSubtitlePreview() async {
        let expected = subtitleGeneration
        guard isSubtitleSheetPresented, let player, !player.isInCall, let item = player.currentItem,
              !item.isVideo, !player.isPresentingVideoPreview else { return }
        if pip.configuredKind == .subtitles, !pip.requiresReconfiguration, !pip.isStopping { return }
        guard await clearPreviousSession(), !Task.isCancelled, !player.isInCall,
              isSubtitleSheetPresented, subtitleGeneration == expected,
              !player.isPresentingVideoPreview else { return }
        updateSubtitleTrack()
        message = nil
        let configured = pip.configure(kind: .subtitles, framesPerSecond: 5, frameProvider: { [weak self] in
            self?.makeSubtitleFrame()
        }, onPlayback: { _ in /* Subtitle buttons never operate the audio player. */ }, onRestore: { [weak self] completion in
            guard let self else { completion(false); return }
            self.restore(.subtitles, completion: completion)
        }, onExternalStop: { [weak self] in
            guard let self else { return }
            self.releaseDisplaySession()
            // Rebuild an idle preview if its settings sheet is still on screen.
            self.pip.clearConfiguration()
            if self.isSubtitleSheetPresented {
                Task { @MainActor [weak self] in await self?.prepareSubtitlePreview() }
            }
        })
        if !configured {
            message = pip.errorMessage ?? InterfaceLocalization.text("此设备暂时无法开启字幕浮窗。")
            refreshSubtitleFallback()
        } else { subtitleFallbackFrame = nil }
    }

    @discardableResult func startSubtitles() -> Bool {
        guard player?.isInCall == false, pip.configuredKind == .subtitles else { return false }
        guard !pip.isActive, !pip.isStarting, !pip.isStopping else { return false }
        guard acquireDisplaySession() else { return false }
        guard pip.start() else {
            message = pip.errorMessage; releaseDisplaySession(); return false
        }
        message = nil
        return true
    }

    /// One bounded attempt per explicit tap, cancelled when the settings source disappears.
    func requestStartSubtitles() {
        subtitleStartRequest?.cancel()
        let attemptID = UUID()
        subtitleStartAttemptID = attemptID
        subtitleStartRequest = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.subtitleStartAttemptID == attemptID {
                    self.subtitleStartAttemptID = nil
                    self.subtitleStartRequest = nil
                    if !self.pip.isActive, !self.pip.isStarting { self.releaseDisplaySession() }
                }
            }
            await self.prepareSubtitlePreview()
            guard !Task.isCancelled, self.isSubtitleSheetPresented else { return }
            guard self.pip.configuredKind == .subtitles else {
                self.message = self.pip.errorMessage ?? InterfaceLocalization.text("此设备暂时无法开启字幕浮窗。")
                self.refreshSubtitleFallback()
                return
            }
            // A paused track has released its audio session. Activate the shared session
            // for this explicit request before asking AVKit whether PiP is possible.
            guard self.acquireDisplaySession() else { return }
            for _ in 0..<40 {
                guard !Task.isCancelled, self.isSubtitleSheetPresented, self.phase == .active,
                      self.player?.isInCall == false, self.pip.configuredKind == .subtitles else { return }
                if self.pip.isPossible { _ = self.startSubtitles(); return }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            self.message = self.pip.errorMessage ?? InterfaceLocalization.text("画中画暂不可用，请稍后重试。")
        }
    }

    func stopSubtitles() {
        subtitleGeneration = UUID()
        subtitleStartRequest?.cancel(); subtitleStartRequest = nil
        guard pip.configuredKind == .subtitles else { return }
        pip.clearConfiguration()
        releaseDisplaySession()
        if isSubtitleSheetPresented {
            Task { @MainActor [weak self] in await self?.prepareSubtitlePreview() }
        }
    }

    func finishSubtitlePreviewIfUnused() {
        subtitleGeneration = UUID()
        subtitleStartRequest?.cancel(); subtitleStartRequest = nil
        subtitleFallbackFrame = nil
        guard pip.configuredKind == .subtitles, !pip.isActive, !pip.isStarting, !pip.isStopping else { return }
        pip.clearConfiguration()
        releaseDisplaySession()
    }

    private func clearPreviousSession() async -> Bool {
        guard pip.configuredKind != nil else { return true }
        pip.clearConfiguration()
        releaseDisplaySession()
        for _ in 0..<60 {
            if pip.configuredKind == nil { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        message = InterfaceLocalization.text("上一个浮窗仍在关闭，请稍后重试。")
        return false
    }

    private func updateSubtitleTrack() {
        guard let player, let subtitles else { return }
        guard let item = player.currentItem, !item.isVideo, let store else {
            subtitleRenderer.setBackground(path: nil, trackID: nil)
            subtitleFallbackFrame = nil
            if pip.configuredKind == .subtitles { stopSubtitles() }
            subtitles.clear(); return
        }
        subtitles.load(item: item, store: store)
        subtitles.update(positionMS: player.positionMS)
        if item.isSavedClip, subtitles.cues.isEmpty, pip.configuredKind == .subtitles { stopSubtitles() }
        refreshSubtitleBackground()
        refreshSubtitleFallback()
    }

    private func refreshSubtitleBackground() {
        guard let item = player?.currentItem, !item.isVideo,
              let store, let work = try? store.work(id: item.workID) else {
            subtitleRenderer.setBackground(path: nil, trackID: nil)
            refreshSubtitleFallback()
            return
        }
        let path: String?
        if work.libraryKind == .personal {
            path = store.creator(id: work.creatorID).flatMap { store.creatorAvatarPath($0) }
        } else { path = store.coverPath(forWorkID: work.id) }
        subtitleRenderer.setBackground(path: path, trackID: item.trackID, revision: store.contentRevision) { [weak self] in
            guard let self else { return }
            self.refreshSubtitleFallback()
            if self.pip.configuredKind == .subtitles { self.pip.refreshFrame() }
        }
        refreshSubtitleFallback()
        if pip.configuredKind == .subtitles { pip.refreshFrame() }
    }

    private func makeSubtitleFrame() -> UIImage? {
        guard let subtitles else { return nil }
        guard let item = player?.currentItem, !item.isVideo else {
            return subtitleRenderer.frameWithoutTrack(options: subtitleOptions)
        }
        return subtitleRenderer.frame(subtitles: subtitles, options: subtitleOptions, expectedTrackID: item.trackID)
    }

    private func observePiPState() {
        callRenderer.setSpatialActive(phase == .active && (visiblePages.contains(.call) || pip.isActive))
        if let error = pip.errorMessage { message = error }
        if pip.configuredKind == .subtitles, !pip.isActive, !pip.isStarting,
           subtitleStartAttemptID == nil { releaseDisplaySession() }
        if pip.configuredKind == .subtitles, !pip.isActive, !pip.isStarting, !pip.isStopping,
           !isSubtitleSheetPresented, restoration == nil, subtitleStartAttemptID == nil {
            pip.clearConfiguration()
        }
        finishRestorationIfVisible()
        // Automatic PiP can start after the app has already returned to its call
        // page. Recheck on native state changes as well as scene/page events.
        returnCallToInlineIfVisible()
    }

    private func refreshSubtitleFallback() {
        guard isSubtitleSheetPresented, pip.configuredKind != .subtitles else { return }
        subtitleFallbackFrame = makeSubtitleFrame()
    }

    private func acquireDisplaySession() -> Bool {
        do { try player?.setPictureInPictureAudioSessionActive(true); return true }
        catch { message = InterfaceLocalization.text("浮窗暂不可用：\(error.localizedDescription)"); return false }
    }

    private func releaseDisplaySession() { try? player?.setPictureInPictureAudioSessionActive(false) }

    private func restore(_ kind: SystemPictureInPictureController.Kind, completion: @escaping (Bool) -> Void) {
        cancelRestoration()
        guard let player, (kind == .call ? player.isInCall : (!player.isVideo && player.currentItem != nil)) else {
            completion(false); return
        }
        let id = UUID()
        restoration = (id, kind, completion)
        isSubtitleSheetPresented = false
        wantsSubtitlePage = kind == .subtitles
        player.isPlayerSheetPresented = true
        finishRestorationIfVisible()
        restoreTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.restoration?.id == id else { return }
            let pending = self.restoration; self.restoration = nil
            self.wantsSubtitlePage = false
            pending?.completion(false)
        }
    }

    private func cancelRestoration() {
        let old = restoration; restoration = nil
        wantsSubtitlePage = false
        restoreTimeout?.cancel(); restoreTimeout = nil
        old?.completion(false)
    }

    private func finishRestorationIfVisible() {
        guard phase == .active, let request = restoration, visiblePages.contains(request.kind),
              !isSubtitleSheetPresented else { return }
        restoration = nil
        restoreTimeout?.cancel(); restoreTimeout = nil
        wantsSubtitlePage = false
        request.completion(true)
    }
}
