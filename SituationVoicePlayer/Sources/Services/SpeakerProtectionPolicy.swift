import Foundation

/// Pure policy, independent of AVAudioSession. Permissions only last for one
/// continuous playback session on one output route, never across a disconnect.
struct SpeakerProtectionPolicy {
    enum Route: Equatable { case speaker, other, unknown }
    private(set) var enabled: Bool
    private(set) var route: Route = .unknown
    private(set) var routeID = ""
    private(set) var activeOwners: Set<String> = []
    private var allowsSpeaker = false
    private var stableAfter: TimeInterval = 0
    private var playbackStartedAt: TimeInterval = 0

    init(enabled: Bool = true) { self.enabled = enabled }
    var isMuted: Bool { enabled && route != .other && !allowsSpeaker }

    mutating func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        allowsSpeaker = false
    }

    mutating func updateRoute(_ route: Route, id: String, at time: TimeInterval) {
        guard self.route != route || routeID != id else { return }
        self.route = route
        routeID = id
        allowsSpeaker = false
        ignoreAutomaticVolumeChanges(at: time)
    }

    mutating func ignoreAutomaticVolumeChanges(at time: TimeInterval) {
        // Route/session changes can restore the system's saved per-route volume.
        stableAfter = max(stableAfter, time + 0.75)
    }

    mutating func beginPlayback(owner: String, at time: TimeInterval) {
        if activeOwners.isEmpty {
            allowsSpeaker = false
            playbackStartedAt = time
            ignoreAutomaticVolumeChanges(at: time)
        }
        activeOwners.insert(owner)
    }

    mutating func endPlayback(owner: String) {
        activeOwners.remove(owner)
        if activeOwners.isEmpty { allowsSpeaker = false }
    }

    mutating func interrupt() {
        activeOwners.removeAll()
        allowsSpeaker = false
    }

    mutating func volumeChanged(from old: Float, to new: Float, routeID: String, at time: TimeInterval) {
        guard enabled, route == .speaker, !activeOwners.isEmpty,
              self.routeID == routeID, time >= stableAfter, time >= playbackStartedAt,
              old.isFinite, new.isFinite, abs(new - old) > 0.0001 else { return }
        allowsSpeaker = true
    }

    mutating func allowCurrentSpeakerPlayback() {
        guard !activeOwners.isEmpty, route == .speaker else { return }
        allowsSpeaker = true
    }
}
