import Foundation
import AVFoundation
#if canImport(SimoAVI)
import SimoAVI
#endif

/// The preview owns its temporary movie until AVPlayer is dismissed.
final class PreparedWorkVideo {
    let url: URL
    private let temporary: Bool

    private init(url: URL, temporary: Bool = false) {
        self.url = url
        self.temporary = temporary
    }

    deinit {
        if temporary { try? FileManager.default.removeItem(at: url) }
    }

    private static func canPlay(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let video = try? await asset.loadTracks(withMediaType: .video).first,
              (try? await video.load(.isPlayable)) == true else { return false }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            return (try? await audio.load(.isPlayable)) == true
        }
        return true
    }

    static func prepare(_ source: URL) async throws -> PreparedWorkVideo {
        if await canPlay(source) { return PreparedWorkVideo(url: source) }
        try Task.checkCancellation()
        #if canImport(SimoAVI)
        if source.pathExtension.lowercased() == "avi" {
            let operation = Task.detached(priority: .userInitiated) {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("simo-preview-" + UUID().uuidString).appendingPathExtension("mov")
                let file = PreparedWorkVideo(url: url, temporary: true)
                let result = simo_remux_avi(source.path, url.path, { Task.isCancelled ? 1 : 0 })
                try Task.checkCancellation()
                guard result == 0, await canPlay(url) else { throw VideoReadError() }
                return file
            }
            return try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
        }
        #endif
        throw VideoReadError()
    }

    private struct VideoReadError: LocalizedError {
        var errorDescription: String? {
            InterfaceLocalization.text("无法播放这份视频。请确认文件可读取、手机有足够空间；若编码不受支持，可通过分享按钮选择其他播放器。")
        }
    }
}
