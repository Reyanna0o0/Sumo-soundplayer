import Foundation
import AVFoundation

enum PlaylistError: LocalizedError {
    case unavailable, missingTrack, invalidRange, incompleteAudio

    var errorDescription: String? {
        switch self {
        case .unavailable: return InterfaceLocalization.text("播放列表尚未就绪。")
        case .missingTrack: return InterfaceLocalization.text("找不到原曲，请重新选择一首媒体库里的曲目。")
        case .invalidRange: return InterfaceLocalization.text("请选择音频范围内的片段，结束位置要晚于起点。")
        case .incompleteAudio: return InterfaceLocalization.text("没有读完整个片段，请检查原音频是否可以播放。")
        }
    }
}

enum AudioClipExporter {
    /// 输出独立、无播放效果的 PCM 文件。调用方提供新的临时 CAF 路径并负责清理。
    static func write(from source: URL, to destination: URL, startMS: Int, endMS: Int) async throws {
        let probe = try AVAudioFile(forReading: source)
        let input: AVAudioFile
        // 默认解码用 Float32。高精度 PCM 按原精度读取，避免整数 32 位或双精度被截断。
        switch probe.fileFormat.commonFormat {
        case .pcmFormatInt16, .pcmFormatInt32, .pcmFormatFloat64:
            input = try AVAudioFile(forReading: source, commonFormat: probe.fileFormat.commonFormat, interleaved: false)
        default:
            input = probe
        }
        let format = input.processingFormat
        let rate = format.sampleRate
        guard startMS >= 0, endMS > startMS, rate.isFinite, rate > 0,
              Double(endMS) <= (Double(input.length) * 1000 / rate).rounded() else {
            throw PlaylistError.invalidRange
        }
        let first = AVAudioFramePosition((Double(startMS) * rate / 1000).rounded())
        let last = min(input.length, AVAudioFramePosition((Double(endMS) * rate / 1000).rounded()))
        guard last > first else { throw PlaylistError.invalidRange }

        let capacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw PlaylistError.incompleteAudio
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        // 部分 MP3 的解码器不支持 seek，设置 framePosition 会直接使进程退出。
        // PCM 可以直接定位；压缩格式顺序解码到起点，内存占用仍只有一个缓冲区。
        let isPCM = input.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM
        if isPCM { input.framePosition = first }
        var remaining = isPCM ? last - first : last
        var skip = isPCM ? 0 : first
        while remaining > 0 {
            try Task.checkCancellation()
            let span = skip > 0 ? skip : remaining
            let count = AVAudioFrameCount(min(span, AVAudioFramePosition(capacity)))
            try input.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { throw PlaylistError.incompleteAudio }
            let frames = AVAudioFramePosition(buffer.frameLength)
            if skip > 0 { skip -= frames }
            else { try output.write(from: buffer) }
            remaining -= frames
        }
    }
}
