import Foundation

/// A user's request, independently of whether a backend can currently render.
public enum PlaybackIntent: Equatable, Sendable {
    case stopped
    case paused
    case playing
}

public enum PlaybackActualState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case waiting
    case playing
    case paused
    case seeking
    case reconnecting
    case ended
    case failed
}

public enum PlaybackBackendKind: String, Hashable, Sendable {
    case localFile
    case remoteStream
}

public struct PlaybackCapabilities: Equatable, Sendable {
    public let canSeek: Bool
    public let rateRange: ClosedRange<Double>

    public init(canSeek: Bool, rateRange: ClosedRange<Double>) {
        self.canSeek = canSeek
        self.rateRange = rateRange
    }
}

public struct PlaybackBackendSnapshot: Equatable, Sendable {
    public let positionMilliseconds: Int64
    public let durationMilliseconds: Int64?
    public let capabilities: PlaybackCapabilities

    public init(positionMilliseconds: Int64, durationMilliseconds: Int64?, capabilities: PlaybackCapabilities) {
        self.positionMilliseconds = positionMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.capabilities = capabilities
    }
}

public enum PlaybackBackendSignal: Equatable, Sendable {
    case playing
    case waiting
    case paused
    case position(milliseconds: Int64, durationMilliseconds: Int64?)
    case ended
    case failed(message: String)
}

/// Adapters must tag all notifications, including delayed KVO/seek callbacks.
public struct PlaybackBackendEvent: Equatable, Sendable {
    public let context: PlaybackContext
    public let signal: PlaybackBackendSignal

    public init(context: PlaybackContext, signal: PlaybackBackendSignal) {
        self.context = context
        self.signal = signal
    }
}

/// A new session invalidates an old load; a new timeline invalidates old seek/clock callbacks.
public struct PlaybackContext: Equatable, Sendable {
    public let sessionID: UUID
    public let timelineGeneration: UInt64
    public init(sessionID: UUID, timelineGeneration: UInt64 = 0) {
        self.sessionID = sessionID
        self.timelineGeneration = timelineGeneration
    }
}

public enum PlaybackCoordinationError: Error, Equatable, Sendable {
    case resolutionFailed(String)
    case resourceRevisionChanged
    case resourceRevisionUnverified
    case resourceIdentityChanged
    case resourceUnavailable
    case preparationRequired
    case incompleteLocalResource
    case missingBackend(PlaybackBackendKind)
    case backendFailed(String)
    case seekingUnsupported
    case invalidPosition
    case unsupportedRate
}
