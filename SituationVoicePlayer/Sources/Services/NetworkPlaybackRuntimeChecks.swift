#if DEBUG && targetEnvironment(simulator)
import Foundation
import ResourceAccessCore
import Combine
import Security
import MediaPlayer

/// Opt-in integration checks against synthetic localhost fixtures. This uses
/// RootView's real PlayerController and subtitle owner; it never ships on a device.
@MainActor
enum NetworkPlaybackRuntimeChecks {
    private static var started = false
    private static var events: [[String: String]] = []
    private static var reportURL: URL?
    private static var protocolName = "http"
    private static let files = ["mp3_cbr.mp3", "m4a_faststart.m4a", "wav_48000_s16_stereo.wav"]
    private struct Failure: Error { let step: String }

    static func runIfRequested(player: PlayerController, store: LibraryStore, subtitles: SubtitleController) async {
        guard !started, let index = CommandLine.arguments.firstIndex(of: "-networkPlaybackCheck"),
              CommandLine.arguments.indices.contains(index + 1),
              let base = URL(string: CommandLine.arguments[index + 1]),
              ["127.0.0.1", "localhost"].contains(base.host ?? "") else { return }
        protocolName = argument("-networkPlaybackProtocol") ?? "http"
        guard ["http", "webdav", "smb", "gate"].contains(protocolName),
              base.scheme == (protocolName == "smb" ? "smb" : "http") else { return }
        started = true
        let buffer = NetworkAudioPlaybackEngine.configuredForwardBufferSeconds
        let suffix = protocolName == "http" && buffer == 0 ? "" : "-\(protocolName)-buffer\(Int(buffer))"
        reportURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("network-playback-check\(suffix).json")
        record("run-start", player: player, extra: ["measurement": "media-clock-not-acoustic", "fixtureHost": "localhost"])
        guard store.repository != nil else { record("bootstrap-failed", player: player); return }
        if protocolName == "gate" {
            do {
                guard let item = store.works.lazy.compactMap({ work in
                    store.queueItems(for: work).first(where: { !$0.isNetworkAudio && !$0.isVideo })
                }).first else { throw Failure(step: "gate-local-item") }
                player.playSingle(item)
                try await wait("gate-local-progress", player: player, timeout: 15) { player.positionMS > 200 }
                try await backupPlaybackGateCheck(player: player)
            } catch { record("backup-gate-failed", player: player,
                extra: ["step": (error as? Failure)?.step ?? diagnostic(error)]) }
            player.pause(immediately: true); record("run-complete", player: player)
            return
        }
        if protocolName != "http" {
            do { try await protocolCheck(base: base, player: player, store: store, subtitles: subtitles) }
            catch { record("protocol-failed", player: player,
                extra: ["step": (error as? Failure)?.step ?? diagnostic(error)]) }
            player.pause(immediately: true)
            record("run-complete", player: player)
            return
        }
        for file in files {
            do { try await check(file: file, base: base, player: player, store: store, subtitles: subtitles) }
            catch {
                record("format-failed", player: player, extra: ["file": file,
                    "step": (error as? Failure)?.step ?? String(describing: type(of: error))])
                player.pause(immediately: true)
                try? await control(base, offline: false)
            }
        }
        do { try await localCheck(base: base, player: player, store: store) }
        catch { record("local-failed", player: player, extra: ["step": (error as? Failure)?.step ?? String(describing: type(of: error))]) }
        do { try await backupPlaybackGateCheck(player: player) }
        catch { record("backup-gate-failed", player: player, extra: ["step": (error as? Failure)?.step ?? String(describing: type(of: error))]) }
        player.pause(immediately: true)
        record("run-complete", player: player)
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    private static func diagnostic(_ error: Error) -> String {
        switch error {
        case ResourceAccessError.authorizationRequired: return "authorizationRequired"
        case ResourceAccessError.permissionDenied: return "permissionDenied"
        case ResourceAccessError.invalidResponse: return "invalidResponse"
        case ResourceAccessError.invalidConfiguration: return "invalidConfiguration"
        case ResourceAccessError.notFound: return "notFound"
        case ResourceAccessError.timedOut: return "timedOut"
        case ResourceAccessError.unsupported: return "unsupported"
        default: return String(describing: type(of: error))
        }
    }

    private static func protocolCheck(base: URL, player: PlayerController, store: LibraryStore,
                                      subtitles: SubtitleController) async throws {
        let service = NetworkLibraryService.shared
        let name = "Synthetic " + protocolName + " " + UUID().uuidString
        let kind: NetworkLibraryKind = protocolName == "smb" ? .smb : .webDAV
        let credentials = NetworkLibraryCredentials(), reference = CredentialReference("synthetic-keychain-" + UUID().uuidString)
        do {
            try credentials.set(.usernamePassword(username: "probe", password: "fixture-only", domain: nil), for: reference)
            guard try credentials.read(reference) != nil else { throw Failure(step: "keychain-read") }
            try credentials.set(nil, for: reference)
            record("keychain-roundtrip", player: player)
        } catch {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "synthetic.runtime.keychain", kSecAttrAccount as String: UUID().uuidString,
                kSecValueData as String: Data("synthetic-only".utf8)]
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecSuccess { SecItemDelete(query as CFDictionary) }
            record("keychain-failed", player: player, extra: ["osStatus": String(status)])
            throw error
        }
        record("protocol-source-start", player: player)
        try await service.save(existing: nil, name: name, kind: kind, address: base.absoluteString,
            username: "probe", password: "fixture-only", domain: "", allowsHTTP: true, requiresEncryption: false)
        record("protocol-source-saved", player: player)
        guard let source = service.sources.first(where: { $0.name == name }) else { throw Failure(step: "protocol-source") }
        let adapter = try await service.adapter(for: source.id)
        let entries = try await adapter.listChildren(at: .root)
        guard let entry = entries.first(where: { $0.path.components.last == "SUMO_TEST_MP3.mp3" }) else {
            throw Failure(step: "protocol-list")
        }
        record("protocol-directory", player: player, extra: ["entries": String(entries.count)])
        let workID = try await service.importSelection(source: source, paths: [entry.path], title: "Synthetic " + protocolName,
            library: .collection, creatorID: nil, coverAssetPath: nil)
        store.reload()
        guard let work = try store.work(id: workID), let item = store.queueItems(for: work).first,
              let subtitlesRepository = store.subtitleRepository else { throw Failure(step: "protocol-queue") }
        _ = try subtitlesRepository.createTrack(trackID: item.trackID, kind: .sidecar, language: "en", label: "Synthetic 5s",
            cues: (0..<36).map { SubtitleCue(index: $0, startMS: $0 * 5_000, endMS: ($0 + 1) * 5_000, text: "Synthetic cue \($0)") })
        player.playSingle(item)
        subtitles.load(item: item, store: store)
        player.isPlayerSheetPresented = true
        try await wait("protocol-first-progress", player: player, timeout: 40) { player.positionMS > 700 }
        record("first-progress", player: player, extra: ["file": "SUMO_TEST_MP3.mp3"])
        try await seek(120_350, player: player, subtitles: subtitles)
        try await seek(17_250, player: player, subtitles: subtitles)
        player.pause(immediately: true)
        let paused = player.positionMS
        player.reconnectNetworkAudio()
        try await wait("protocol-paused-reconnect", player: player, timeout: 40) { !player.isLoadingMedia }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard !player.isPlaying, abs(player.positionMS - paused) < 200 else { throw Failure(step: "protocol-pause-lost") }
        player.resume()
        try await wait("protocol-resume", player: player, timeout: 25) { player.positionMS > paused + 700 }
        record("protocol-passed", player: player)
    }

    private static func check(file: String, base: URL, player: PlayerController,
                              store: LibraryStore, subtitles: SubtitleController) async throws {
        try await control(base, offline: false)
        let service = NetworkLibraryService.shared
        let name = "Synthetic check " + UUID().uuidString
        try await service.save(existing: nil, name: name, kind: .http,
            address: base.appendingPathComponent("media").appendingPathComponent(file).absoluteString,
            username: "", password: "", domain: "", allowsHTTP: true, requiresEncryption: false)
        guard let source = service.sources.first(where: { $0.name == name }), let path = source.directHTTPPath else {
            throw Failure(step: "source")
        }
        let workID = try await service.importSelection(source: source, paths: [path], title: "Synthetic " + file,
            library: .collection, creatorID: nil, coverAssetPath: nil)
        store.reload()
        guard let work = try store.work(id: workID), let item = store.queueItems(for: work).first, item.isNetworkAudio,
              let subtitleRepository = store.subtitleRepository else { throw Failure(step: "network-queue") }
        let cues = (0..<36).map { SubtitleCue(index: $0, startMS: $0 * 5_000, endMS: ($0 + 1) * 5_000, text: "Synthetic cue \($0)") }
        _ = try subtitleRepository.createTrack(trackID: item.trackID, kind: .sidecar, language: "en", label: "Synthetic 5s", cues: cues)
        // The second queue entry is a sentinel: a source failure must not select it.
        var sentinel = item; sentinel.id = UUID()
        player.play(items: [item, sentinel])
        subtitles.load(item: item, store: store)
        player.isPlayerSheetPresented = true
        try await wait("first-progress", player: player, timeout: 40) { player.positionMS > 600 }
        record("first-progress", player: player, extra: ["file": file])
        try await seek(120_350, player: player, subtitles: subtitles)
        try await seek(17_250, player: player, subtitles: subtitles)

        player.rate = 1.5
        let startup = player.positionMS
        try await wait("rate-startup", player: player, timeout: 20) {
            player.positionMS > startup + 1_500 && !player.isWaitingForNetwork
        }
        let speedStart = player.positionMS, wall = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let elapsed = ProcessInfo.processInfo.systemUptime - wall
        let observed = Double(player.positionMS - speedStart) / 1_000 / elapsed
        record("rate-sample", player: player, extra: ["file": file, "observed": String(observed),
            "passed": String(observed >= 1.15 && observed <= 1.85)])
        guard observed >= 1.15 && observed <= 1.85 else { throw Failure(step: "rate-sample") }
        player.rate = 1

        // Pause must win over a seek completion that arrives later.
        player.seek(to: 65_250); player.pause(immediately: true)
        try await wait("paused-seek-position", player: player, timeout: 25) { abs(player.positionMS - 65_250) < 700 }
        let paused = player.positionMS
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard !player.isPlaying, abs(player.positionMS - paused) < 150 else { throw Failure(step: "pause-lost-to-seek") }
        record("pause-wins-seek", player: player, extra: ["file": file])

        player.reconnectNetworkAudio()
        try await wait("paused-reconnect", player: player, timeout: 40) { !player.isLoadingMedia && abs(player.positionMS - paused) < 700 }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard !player.isPlaying, abs(player.positionMS - paused) < 150 else { throw Failure(step: "pause-lost-to-reconnect") }
        record("pause-wins-reconnect", player: player, extra: ["file": file])

        // Re-selecting begins async metadata/item loading; immediate pause must survive readiness.
        player.play(items: [item, sentinel]); player.pause(immediately: true)
        try await wait("paused-load", player: player, timeout: 40) { !player.isLoadingMedia }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard !player.isPlaying else { throw Failure(step: "pause-lost-to-load") }
        record("pause-wins-load", player: player, extra: ["file": file])
        player.resume()
        let beforeResume = player.positionMS
        try await wait("resume", player: player, timeout: 25) { player.positionMS > beforeResume + 700 }

        try await control(base, offline: true)
        // Leave more than the 25 s observation window before natural EOF, so
        // an entirely buffered item ending normally cannot look like auto-skip.
        player.seek(to: 140_350)
        let until = ProcessInfo.processInfo.systemUptime + 25
        while player.errorMessage == nil, ProcessInfo.processInfo.systemUptime < until {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard player.currentItem?.id == item.id else { throw Failure(step: "source-failure-skipped-track") }
        record(player.errorMessage == nil ? "offline-inconclusive-still-buffered" : "offline-error-retained-track",
            player: player, extra: ["file": file])
        player.pause(immediately: true)
        try await control(base, offline: false)
        player.reconnectNetworkAudio()
        try await wait("offline-reconnect-paused", player: player, timeout: 40) { !player.isLoadingMedia }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        guard !player.isPlaying else { throw Failure(step: "offline-reconnect-ignored-user-pause") }
        player.resume()
        let beforeRecovery = player.positionMS
        try await wait("recovered-progress", player: player, timeout: 25) { player.positionMS > beforeRecovery + 500 }
        record("format-passed", player: player, extra: ["file": file])
        player.pause(immediately: true)
    }

    private static func seek(_ target: Int, player: PlayerController, subtitles: SubtitleController) async throws {
        let start = ProcessInfo.processInfo.systemUptime
        player.seek(to: target)
        try await wait("seek-arrival", player: player, timeout: 25) { abs(player.positionMS - target) < 1_000 }
        let arrived = player.positionMS
        try await wait("seek-progress", player: player, timeout: 20) { player.positionMS > target + 700 }
        let expected = player.positionMS / 5_000
        let displayed = subtitles.currentCue?.index ?? -1
        record("seek", player: player, extra: ["requested": String(target), "arrival": String(arrived),
            "elapsed": String(ProcessInfo.processInfo.systemUptime - start),
            "subtitleExpected": String(expected), "subtitleActual": String(displayed)])
        guard expected == displayed else { throw Failure(step: "subtitle-clock") }
    }

    private static func localCheck(base: URL, player: PlayerController, store: LibraryStore) async throws {
        try await control(base, offline: false)
        var components = URLComponents(url: base.appendingPathComponent("media/mp3_cbr.mp3"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "run", value: UUID().uuidString + "-local-download"), .init(name: "download", value: "1")]
        let (downloaded, response) = try await URLSession.shared.download(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(step: "local-download") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try FileManager.default.moveItem(at: downloaded, to: target)
        defer { try? FileManager.default.removeItem(at: target) }
        let before = Set(store.works.map(\.id))
        try await store.importAudioWorks([target], library: .collection, creatorID: nil)
        guard let work = store.works.first(where: { !before.contains($0.id) }),
              let item = store.queueItems(for: work).first, !item.isNetworkAudio else { throw Failure(step: "local-import") }
        player.playSingle(item)
        try await wait("local-progress", player: player, timeout: 15) { player.positionMS > 700 }
        player.seek(to: 17_250)
        try await wait("local-seek", player: player, timeout: 15) { player.positionMS > 17_750 }
        player.pause(immediately: true)
        record("local-passed", player: player)
    }

    private static func backupPlaybackGateCheck(player: PlayerController) async throws {
        guard let original = player.currentItem else { throw Failure(step: "backup-gate-no-item") }
        player.pause(immediately: true)
        let position = player.positionMS
        var checked = false, protected = false
        let coordinator = LibraryBackupCoordinator.shared
        let subscription = coordinator.$isBusy.sink { busy in
            guard busy, !checked else { return }
            checked = true
            let ticket = player.captureRemoteCommandTicket()
            let accepted = player.executeRemoteCommand(.play, ticket: ticket)
            player.resume(); player.seek(to: 33_000); player.next(); player.previous()
            var replacement = original; replacement.id = UUID()
            player.playSingle(replacement)
            protected = !accepted && !player.isPlaying && player.currentItem?.id == original.id && player.positionMS == position
            // Do not write the test report while the backup is copying Documents.
        }
        let archive = await coordinator.export()
        subscription.cancel()
        if let archive { coordinator.removeExport(archive) }
        guard checked, protected, archive != nil else { throw Failure(step: "backup-gate-or-export") }
        guard MPRemoteCommandCenter.shared().playCommand.isEnabled else { throw Failure(step: "backup-remote-still-disabled") }
        let ticket = player.captureRemoteCommandTicket()
        guard player.executeRemoteCommand(.play, ticket: ticket) else { throw Failure(step: "backup-remote-ticket-rejected") }
        try await wait("backup-remote-resumed", player: player, timeout: 15) { player.positionMS > position + 500 }
        player.pause(immediately: true)
        record("backup-playback-gate-passed", player: player, extra: ["remoteReenabled": "true", "actualResume": "true"])
    }

    private static func wait(_ step: String, player: PlayerController, timeout: Double,
                             condition: () -> Bool) async throws {
        let until = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < until {
            if player.errorMessage != nil { throw Failure(step: step + ":playback-error") }
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        record("timeout", player: player, extra: ["step": step])
        throw Failure(step: step + ":timeout")
    }

    private static func control(_ base: URL, offline: Bool) async throws {
        var components = URLComponents(url: base.appendingPathComponent("control"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "run", value: "default"), .init(name: "mode", value: offline ? "offline" : "online")]
        let (_, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(step: "fixture-control") }
    }

    private static func record(_ stage: String, player: PlayerController, extra: [String: String] = [:]) {
        var row = extra
        row["stage"] = stage; row["timestamp"] = ISO8601DateFormatter().string(from: Date())
        row["protocol"] = protocolName
        row["forwardBufferSeconds"] = String(NetworkAudioPlaybackEngine.configuredForwardBufferSeconds)
        row["positionMS"] = String(player.positionMS); row["durationMS"] = String(player.durationMS)
        row["playIntent"] = String(player.isPlaying); row["loading"] = String(player.isLoadingMedia)
        row["waiting"] = String(player.isWaitingForNetwork); row["hasError"] = String(player.errorMessage != nil)
        row["network"] = String(player.isNetworkAudio)
        events.append(row)
        if let reportURL, let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
        }
    }
}
#endif
