import AVFoundation
import Combine
import Foundation

/// App-local output gate. Never writes the device's volume or starts playback.
@MainActor
final class SpeakerProtection: ObservableObject {
    static let shared = SpeakerProtection()
    static let settingKey = "hibiki.playback.speakerProtection"
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.settingKey)
            policy.setEnabled(isEnabled)
            policy.ignoreAutomaticVolumeChanges(at: ProcessInfo.processInfo.systemUptime)
            refreshRoute()
            publishMute()
        }
    }
    @Published private(set) var isMuted: Bool
    @Published private(set) var isPlaybackActive = false
    private var policy: SpeakerProtectionPolicy
    private var volumeObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let enabled = UserDefaults.standard.object(forKey: Self.settingKey) as? Bool ?? true
        isEnabled = enabled
        policy = SpeakerProtectionPolicy(enabled: enabled)
        isMuted = enabled
        refreshRoute()
        let session = AVAudioSession.sharedInstance()
        volumeObservation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] session, change in
            guard let old = change.oldValue, let new = change.newValue else { return }
            let route = Self.routeSnapshot(session)
            let time = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Read the route again: the volume callback may precede the
                // matching route notification or wait behind a pause on main.
                self.refreshRoute()
                self.policy.volumeChanged(from: old, to: new, routeID: route.id, at: time)
                self.publishMute()
            }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.policy.ignoreAutomaticVolumeChanges(at: ProcessInfo.processInfo.systemUptime)
                self.refreshRoute()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated {
                self?.policy.interrupt()
                self?.publishMute()
            }
        })
    }

    /// Call before session activation and before any source is allowed to render.
    func prepareForActivation() {
        policy.ignoreAutomaticVolumeChanges(at: ProcessInfo.processInfo.systemUptime)
        refreshRoute()
    }

    func beginPlayback(owner: String) {
        refreshRoute()
        policy.beginPlayback(owner: owner, at: ProcessInfo.processInfo.systemUptime)
        publishMute()
    }

    func endPlayback(owner: String) {
        policy.endPlayback(owner: owner)
        publishMute()
    }

    func allowCurrentSpeakerPlayback() {
        refreshRoute()
        policy.allowCurrentSpeakerPlayback()
        publishMute()
    }

    private func refreshRoute() {
        let route = Self.routeSnapshot(AVAudioSession.sharedInstance())
        policy.updateRoute(route.kind, id: route.id, at: ProcessInfo.processInfo.systemUptime)
        publishMute()
    }

    private func publishMute() {
        let active = !policy.activeOwners.isEmpty
        if isPlaybackActive != active { isPlaybackActive = active }
        if isMuted != policy.isMuted { isMuted = policy.isMuted }
    }

    private nonisolated static func routeSnapshot(_ session: AVAudioSession) -> (kind: SpeakerProtectionPolicy.Route, id: String) {
        let outputs = session.currentRoute.outputs
        let kind: SpeakerProtectionPolicy.Route = outputs.isEmpty ? .unknown
            : (outputs.contains { $0.portType == .builtInSpeaker } ? .speaker : .other)
        let id = outputs.map { "\($0.portType.rawValue):\($0.uid)" }.sorted().joined(separator: "|")
        return (kind, id)
    }

    deinit {
        volumeObservation?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
