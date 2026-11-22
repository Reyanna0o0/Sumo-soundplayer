import AVFoundation
import Combine
import UIKit

struct OpeningVoiceSelection: Codable, Equatable {
    enum Kind: String, Codable { case track, clip }
    var kind: Kind
    var id: Int64
    var title: String
    static let defaultsKey = "openingVoiceSelection.v1"

    static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    @MainActor func resolve(in store: LibraryStore) throws -> OpeningVoiceFile {
        if kind == .clip {
            guard let entry = store.playlistEntries.first(where: { $0.id == id && $0.isClip }),
                  let item = store.playlistItem(for: entry) else { throw OpeningVoiceError.unavailable }
            return OpeningVoiceFile(url: URL(fileURLWithPath: item.filePath), lease: nil)
        }
        guard let track = try store.repository?.track(id: id), !track.isVideo,
              let work = try store.work(id: track.workID),
              let path = store.resolveTrackPath(track, work: work) else { throw OpeningVoiceError.unavailable }
        // Keep a source-directory lease for external files for the entire short playback.
        let lease: WorkAttachmentDirectoryLease?
        if track.assetRelativePath == nil, let source = store.attachmentSource(for: work) {
            lease = try WorkAttachmentAccess.open(source)
        } else { lease = nil }
        guard FileManager.default.fileExists(atPath: path) else { throw OpeningVoiceError.unavailable }
        return OpeningVoiceFile(url: URL(fileURLWithPath: path), lease: lease)
    }
}

struct OpeningVoiceFile {
    let url: URL
    let lease: WorkAttachmentDirectoryLease?
}

enum OpeningVoiceError: LocalizedError {
    case unavailable, unreadable
    var errorDescription: String? {
        switch self {
        case .unavailable: InterfaceLocalization.text("所选音频暂时找不到，请重新关联原文件，或选择其他开屏语音。")
        case .unreadable: InterfaceLocalization.text("暂时无法播放这份音频，请选择其他音频或摘选。")
        }
    }
}

/// Separate from the work queue: launch audio never changes listening history or resume positions.
@MainActor
final class OpeningVoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = OpeningVoicePlayer()
    nonisolated static let maximumDuration: TimeInterval = 10
    @Published private(set) var isPlaying = false
    @Published private(set) var message: String?
    private var audio: AVAudioPlayer?
    private var file: OpeningVoiceFile?
    private var stopTask: Task<Void, Never>?
    private var ownsSession = false
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { self?.stop() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { self?.stop() }
        })
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    static func duration(for file: OpeningVoiceFile) throws -> TimeInterval {
        let audio = try AVAudioPlayer(contentsOf: file.url)
        guard audio.duration.isFinite, audio.duration > 0 else { throw OpeningVoiceError.unreadable }
        return min(maximumDuration, audio.duration)
    }

    func startSelection(in store: LibraryStore, automatic: Bool) {
        guard let selection = OpeningVoiceSelection.load() else { return }
        if automatic && (UIApplication.shared.applicationState == .background || AVAudioSession.sharedInstance().isOtherAudioPlaying) { return }
        stop()
        do { try start(selection.resolve(in: store)) }
        catch { message = error.localizedDescription }
    }

    func start(_ file: OpeningVoiceFile, limit: TimeInterval = maximumDuration) throws {
        stop()
        message = nil
        let audio = try AVAudioPlayer(contentsOf: file.url)
        guard audio.duration.isFinite, audio.duration > 0, limit.isFinite, limit > 0 else { throw OpeningVoiceError.unreadable }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
            ownsSession = true
            self.file = file
            self.audio = audio
            audio.delegate = self
            audio.numberOfLoops = 0
            guard audio.play() else { throw OpeningVoiceError.unreadable }
            isPlaying = true
            let duration = min(Self.maximumDuration, min(limit, audio.duration))
            stopTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(duration)) } catch { return }
                self?.stop()
            }
        } catch { stop(); throw error }
    }

    func stop() {
        stopTask?.cancel(); stopTask = nil
        audio?.stop(); audio = nil; file = nil
        isPlaying = false
        if ownsSession {
            ownsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audio === player else { return }
            self.stop()
        }
    }
}

/// One process-wide cold start, including when SwiftUI recreates the root view.
@MainActor
final class LaunchExperience: ObservableObject {
    static let shared = LaunchExperience()
    @Published private(set) var isShowing = true
    private var didBegin = false

    func begin(store: LibraryStore) {
        guard !didBegin else { return }
        didBegin = true
        OpeningVoicePlayer.shared.startSelection(in: store, automatic: true)
    }

    /// Replay only the visual layer. The process-wide opening-voice gate stays
    /// consumed, and the settings page remains mounted underneath the dissolve.
    func preview() { isShowing = true }

    func finish() { isShowing = false }
}
