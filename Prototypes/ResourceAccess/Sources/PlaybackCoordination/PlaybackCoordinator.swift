import Foundation
import ResourceAccessCore

/// A small, platform-independent control layer. It does not own a queue or
/// infer that a network outage means the user wants to play the next track.
@MainActor
public final class PlaybackCoordinator {
    public private(set) var intent: PlaybackIntent = .stopped
    public private(set) var actualState: PlaybackActualState = .idle
    public private(set) var identity: TrackIdentity?
    public private(set) var resource: ResolvedResource?
    public private(set) var activeBackendKind: PlaybackBackendKind?
    public private(set) var context: PlaybackContext?
    public private(set) var positionMilliseconds: Int64 = 0
    public private(set) var durationMilliseconds: Int64?
    public private(set) var capabilities: PlaybackCapabilities?
    public private(set) var requestedSeekMilliseconds: Int64?
    public private(set) var rate: Double = 1
    public private(set) var error: PlaybackCoordinationError?

    /// Subtitles use actual media time, never wall time or the drag preview.
    public var subtitlePositionMilliseconds: Int64 { positionMilliseconds }
    /// Conservative wall seconds corroborated by advancing media samples.
    /// Each interval is capped by mediaDelta / requestedRate; waiting, seek,
    /// prepare and frozen clocks add nothing. The getter never extrapolates.
    /// This is NOT an acoustic measurement or persisted per-track statistics.
    public var listeningSeconds: TimeInterval { accumulatedListening }

    private let resolver: any ResourceResolver
    private let backends: [PlaybackBackendKind: any PlaybackBackend]
    private let clock: @MainActor () -> TimeInterval
    private var activeBackend: (any PlaybackBackend)?
    private var ready = false
    private var seekInFlight = false
    private var pendingSeek: Int64?
    private var seekTask: Task<Void, Never>?
    private var accumulatedListening: TimeInterval = 0
    private struct ListeningSample {
        let wallTime: TimeInterval
        let mediaMilliseconds: Int64
        let rate: Double
    }
    private var listeningBaseline: ListeningSample?
    // Keep identity evidence after a transport/prepare failure without retaining a file lease.
    private var lastRevision: ResourceRevision?
    private var lastLocation: ResourceLocation?
    private var lastWasRemote = false
    /// Survives failed restoration; never substitutes for the subtitle/media clock.
    private var recoveryPositionMilliseconds: Int64 = 0

    public init(resolver: any ResourceResolver, backends: [any PlaybackBackend],
                clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.resolver = resolver
        self.backends = Dictionary(backends.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.clock = clock
        for backend in self.backends.values {
            let kind = backend.kind
            backend.eventHandler = { [weak self] event in self?.receive(event, from: kind) }
        }
    }

    public func select(_ identity: TrackIdentity, autoplay: Bool = true,
                       startingAtMilliseconds: Int64 = 0) async {
        guard startingAtMilliseconds >= 0 else { error = .invalidPosition; return }
        invalidateActive()
        self.identity = identity
        lastRevision = nil
        lastLocation = nil
        lastWasRemote = false
        recoveryPositionMilliseconds = startingAtMilliseconds
        positionMilliseconds = 0
        durationMilliseconds = nil
        capabilities = nil
        setIntent(autoplay ? .playing : .paused)
        let current = PlaybackContext(sessionID: UUID())
        context = current
        error = nil
        transition(.preparing)
        await prepare(identity, expectedRevision: nil, previousLocation: nil,
                      requiresCompleteLocalFallback: false, restorePosition: startingAtMilliseconds, context: current)
    }

    /// Explicitly reopen the same logical track. No URL is retained as its identity.
    /// The resolver may refresh credentials/URLs or find a verified complete copy.
    public func reconnect() async {
        guard let identity else { return }
        let oldPosition = recoveryPositionMilliseconds
        let expected = lastRevision
        let oldLocation = lastLocation
        let wasRemote = lastWasRemote
        invalidateActive()
        let current = PlaybackContext(sessionID: UUID())
        context = current
        error = nil
        transition(.reconnecting)
        await prepare(identity, expectedRevision: expected, previousLocation: oldLocation,
                      requiresCompleteLocalFallback: wasRemote, restorePosition: oldPosition, context: current)
    }

    public func play() {
        guard identity != nil, actualState != .failed, actualState != .ended else { return }
        setIntent(.playing)
        applyIntentIfReady()
    }

    public func pause() {
        setIntent(.paused)
        if let context { activeBackend?.pause(context: context) }
        if identity != nil { transition(.paused) }
    }

    /// Timer expiry follows exactly the same priority as a user's pause.
    public func sleepTimerExpired() { pause() }

    public func stop() {
        setIntent(.stopped)
        invalidateActive()
        identity = nil
        lastRevision = nil
        lastLocation = nil
        lastWasRemote = false
        recoveryPositionMilliseconds = 0
        capabilities = nil
        durationMilliseconds = nil
        positionMilliseconds = 0
        error = nil
        transition(.idle)
    }

    public func setRate(_ value: Double) throws {
        guard value.isFinite, value > 0,
              capabilities?.rateRange.contains(value) ?? (value == 1) else {
            throw PlaybackCoordinationError.unsupportedRate
        }
        rate = value
        resetListeningBaseline()
        if ready, !seekInFlight, intent == .playing, let context {
            activeBackend?.play(rate: rate, context: context)
        }
    }

    /// One seek at a time; intermediate pending destinations are replaced.
    /// A drag preview is exposed separately from the authoritative media clock.
    public func seek(toMilliseconds target: Int64) throws {
        guard target >= 0 else { throw PlaybackCoordinationError.invalidPosition }
        guard ready, capabilities?.canSeek == true, let current = context else {
            throw PlaybackCoordinationError.seekingUnsupported
        }
        pendingSeek = target
        recoveryPositionMilliseconds = target
        requestedSeekMilliseconds = target
        activeBackend?.pause(context: current)
        transition(.seeking)
        guard !seekInFlight else { return }
        seekInFlight = true
        seekTask = Task { [weak self] in await self?.drainSeeks(sessionID: current.sessionID) }
    }

    private func prepare(_ identity: TrackIdentity, expectedRevision: ResourceRevision?,
                         previousLocation: ResourceLocation?, requiresCompleteLocalFallback: Bool,
                         restorePosition: Int64, context current: PlaybackContext) async {
        var obtainedResource: ResolvedResource?
        do {
            let resolved = try await resolver.resolve(identity, expectedRevision: expectedRevision)
            obtainedResource = resolved
            guard context == current, !Task.isCancelled else {
                await resolved.lease?.release()
                cancelCurrentIfNeeded(current)
                return
            }
            guard resolved.identity == identity else { throw PlaybackCoordinationError.resourceIdentityChanged }
            if let expectedRevision {
                let moved = previousLocation.map {
                    $0.sourceID != resolved.location.sourceID || $0.path != resolved.location.path
                } ?? false
                let revisionMatch = moved
                    ? expectedRevision.contentMatchAcrossLocations(resolved.probe.metadata.revision)
                    : expectedRevision.match(resolved.probe.metadata.revision)
                switch revisionMatch {
                case .different: throw PlaybackCoordinationError.resourceRevisionChanged
                case .unknown:
                    if moved {
                        throw PlaybackCoordinationError.resourceRevisionUnverified
                    }
                case .same: break
                }
            }
            let kind = try backendKind(for: resolved, fallbackFromRemote: requiresCompleteLocalFallback)
            guard let backend = backends[kind] else { throw PlaybackCoordinationError.missingBackend(kind) }
            resource = resolved
            lastRevision = resolved.probe.metadata.revision
            lastLocation = resolved.location
            lastWasRemote = kind == .remoteStream
            activeBackend = backend
            activeBackendKind = kind
            obtainedResource = nil // ownership transferred to active session
            let snapshot = try await backend.load(resolved, context: current)
            guard context == current, !Task.isCancelled else { cancelCurrentIfNeeded(current); return }
            // Opening a replacement item at zero must not erase the resume point
            // if its subsequent restore seek fails.
            apply(snapshot, updatePosition: restorePosition == 0)
            ready = true
            if restorePosition > 0 {
                guard snapshot.capabilities.canSeek else { throw PlaybackCoordinationError.seekingUnsupported }
                // Mark restoring seeks as in-flight, so early backend callbacks cannot resume.
                seekInFlight = true
                requestedSeekMilliseconds = restorePosition
                transition(.seeking)
                let seekContext = PlaybackContext(sessionID: current.sessionID, timelineGeneration: 1)
                context = seekContext
                let restored = try await backend.seek(toMilliseconds: restorePosition, context: seekContext)
                guard context == seekContext, !Task.isCancelled else { cancelCurrentIfNeeded(seekContext); return }
                // User requests made during restore take precedence over this result.
                if pendingSeek == nil { apply(restored) }
                seekInFlight = false
                if pendingSeek != nil {
                    seekInFlight = true
                    seekTask = Task { [weak self] in await self?.drainSeeks(sessionID: current.sessionID) }
                    return
                }
                requestedSeekMilliseconds = nil
            }
            applyIntentIfReady()
        } catch {
            await obtainedResource?.lease?.release()
            guard context?.sessionID == current.sessionID else { return }
            if Task.isCancelled { stop(); return }
            fail(error)
        }
    }

    private func backendKind(for resolved: ResolvedResource, fallbackFromRemote: Bool) throws -> PlaybackBackendKind {
        guard resolved.probe.availability == .ready else { throw PlaybackCoordinationError.resourceUnavailable }
        switch resolved.probe.playbackAccess {
        case .localFile(let url):
            guard url.isFileURL,
                  resolved.probe.residency == .applicationOwnedComplete || resolved.probe.residency == .externalManaged else {
                throw PlaybackCoordinationError.incompleteLocalResource
            }
            if fallbackFromRemote && resolved.probe.residency != .applicationOwnedComplete {
                throw PlaybackCoordinationError.incompleteLocalResource
            }
            return .localFile
        case .httpURL(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw PlaybackCoordinationError.preparationRequired
            }
            return .remoteStream
        case .byteReader, .requiresPreparation: throw PlaybackCoordinationError.preparationRequired
        case .unavailable: throw PlaybackCoordinationError.resourceUnavailable
        }
    }

    private func drainSeeks(sessionID: UUID) async {
        while let target = pendingSeek, let previousContext = context,
              previousContext.sessionID == sessionID, let backend = activeBackend {
            pendingSeek = nil
            let current = PlaybackContext(sessionID: sessionID, timelineGeneration: previousContext.timelineGeneration &+ 1)
            context = current
            do {
                let snapshot = try await backend.seek(toMilliseconds: target, context: current)
                guard context == current, !Task.isCancelled else { return }
                if pendingSeek != nil { continue }
                apply(snapshot)
                requestedSeekMilliseconds = nil
                seekInFlight = false
                seekTask = nil
                applyIntentIfReady()
                return
            } catch {
                guard context == current, !Task.isCancelled else { return }
                if pendingSeek != nil { continue }
                seekInFlight = false
                seekTask = nil
                fail(error)
                return
            }
        }
    }

    private func applyIntentIfReady() {
        guard ready, !seekInFlight, let context, let backend = activeBackend else { return }
        if intent == .playing {
            // A play request is not evidence of rendering. Backend must report playing.
            transition(.waiting)
            backend.play(rate: rate, context: context)
        } else {
            backend.pause(context: context)
            transition(.paused)
        }
    }

    private func receive(_ event: PlaybackBackendEvent, from kind: PlaybackBackendKind) {
        guard activeBackendKind == kind, context == event.context else { return }
        switch event.signal {
        case .playing:
            guard ready, !seekInFlight, intent == .playing else {
                activeBackend?.pause(context: event.context)
                return
            }
            transition(.playing)
        case .waiting:
            if ready, !seekInFlight, intent == .playing { transition(.waiting) }
        case .paused:
            if ready, !seekInFlight { transition(intent == .playing ? .waiting : .paused) }
        case .position(let milliseconds, let duration):
            guard ready, !seekInFlight else { return }
            recordMediaProgress(max(0, milliseconds))
            positionMilliseconds = max(0, milliseconds)
            recoveryPositionMilliseconds = positionMilliseconds
            durationMilliseconds = duration
        case .ended:
            guard ready, !seekInFlight else { return }
            setIntent(.paused)
            transition(.ended)
        case .failed(let message): fail(PlaybackCoordinationError.backendFailed(message))
        }
    }

    private func apply(_ snapshot: PlaybackBackendSnapshot, updatePosition: Bool = true) {
        if updatePosition {
            positionMilliseconds = max(0, snapshot.positionMilliseconds)
            recoveryPositionMilliseconds = positionMilliseconds
        }
        durationMilliseconds = snapshot.durationMilliseconds
        capabilities = snapshot.capabilities
        if !snapshot.capabilities.rateRange.contains(rate) { rate = 1 }
    }

    private func fail(_ failure: Error) {
        listeningBaseline = nil
        error = failure as? PlaybackCoordinationError ??
            ((failure as? ResourceAccessError) == .resourceChanged ? .resourceRevisionChanged : .backendFailed(String(describing: failure)))
        context = nil
        activeBackend?.stop()
        activeBackend = nil
        activeBackendKind = nil
        if let lease = resource?.lease { Task { await lease.release() } }
        resource = nil
        seekTask?.cancel()
        seekTask = nil
        ready = false
        seekInFlight = false
        pendingSeek = nil
        requestedSeekMilliseconds = nil
        transition(.failed)
    }

    private func cancelCurrentIfNeeded(_ current: PlaybackContext) {
        if context == current, Task.isCancelled { stop() }
    }

    private func invalidateActive() {
        listeningBaseline = nil
        context = nil
        ready = false
        seekTask?.cancel()
        seekTask = nil
        seekInFlight = false
        pendingSeek = nil
        requestedSeekMilliseconds = nil
        activeBackend?.stop()
        activeBackend = nil
        activeBackendKind = nil
        if let lease = resource?.lease { Task { await lease.release() } }
        resource = nil
    }

    private var countsListening: Bool { intent == .playing && actualState == .playing && ready && !seekInFlight }
    private func recordMediaProgress(_ milliseconds: Int64) {
        guard countsListening else { listeningBaseline = nil; return }
        let now = clock()
        if let baseline = listeningBaseline, milliseconds > baseline.mediaMilliseconds {
            let wallDelta = max(0, now - baseline.wallTime)
            let mediaDelta = Double(milliseconds - baseline.mediaMilliseconds) / 1_000
            accumulatedListening += min(wallDelta, mediaDelta / baseline.rate)
        }
        // Even an unchanged sample advances the baseline: a later jump cannot
        // retroactively credit an observed period with no media progress.
        listeningBaseline = ListeningSample(wallTime: now, mediaMilliseconds: milliseconds, rate: rate)
    }
    private func resetListeningBaseline() {
        listeningBaseline = countsListening
            ? ListeningSample(wallTime: clock(), mediaMilliseconds: positionMilliseconds, rate: rate) : nil
    }
    private func setIntent(_ intent: PlaybackIntent) {
        guard self.intent != intent else { return }
        self.intent = intent
        resetListeningBaseline()
    }
    private func transition(_ state: PlaybackActualState) {
        guard actualState != state else { return }
        actualState = state
        resetListeningBaseline()
    }
}
