import AVFoundation

enum AudioClipMerger {
    struct Output: Sendable {
        let durationMS: Int
        let segmentDurationsMS: [Int]
    }

    enum MergeError: LocalizedError {
        case tooFewClips, cannotConvert

        var errorDescription: String? {
            switch self {
            case .tooFewClips: return InterfaceLocalization.text("至少选择两个摘选。")
            case .cannotConvert: return InterfaceLocalization.text("这些摘选的音频格式无法合并。")
            }
        }
    }

    /// 依次写入临时 CAF。调用方只在整个文件写完后将其加入播放列表。
    static func write(sources: [URL], to destination: URL) async throws -> Int {
        try await writeWithTimeline(sources: sources, to: destination).durationMS
    }

    /// Frame-derived boundaries keep subtitle offsets aligned after resampling.
    static func writeWithTimeline(sources: [URL], to destination: URL) async throws -> Output {
        guard sources.count >= 2 else { throw MergeError.tooFewClips }
        let formats = try sources.map { try AVAudioFile(forReading: $0).processingFormat }
        guard let maxRate = formats.map(\.sampleRate).max(),
              let channels = formats.max(by: { $0.channelCount < $1.channelCount }),
              let format = AVAudioFormat(standardFormatWithSampleRate: maxRate, channels: channels.channelCount)
        else { throw MergeError.cannotConvert }

        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: false)
        var totalFrames: AVAudioFramePosition = 0
        var boundariesMS = [0]
        for url in sources {
            try Task.checkCancellation()
            let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard input.length > 0 else { throw PlaylistError.incompleteAudio }
            totalFrames += try append(input, to: output)
            boundariesMS.append(Int((Double(totalFrames) * 1000 / maxRate).rounded()))
        }
        return Output(durationMS: boundariesMS.last ?? 0,
                      segmentDurationsMS: zip(boundariesMS.dropFirst(), boundariesMS).map { $0 - $1 })
    }

    private static func append(_ input: AVAudioFile, to output: AVAudioFile) throws -> AVAudioFramePosition {
        let capacity: AVAudioFrameCount = 16_384
        guard let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity),
              let converted = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: capacity),
              let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat)
        else { throw MergeError.cannotConvert }
        // 单声道在立体声合辑中放在中央，两只耳朵都应听得到。
        if input.processingFormat.channelCount == 1 && output.processingFormat.channelCount == 2 {
            converter.channelMap = [0, 0]
        }
        var readError: Error?
        var written: AVAudioFramePosition = 0
        while true {
            try Task.checkCancellation()
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { requested, state in
                guard input.framePosition < input.length else {
                    state.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: source, frameCount: min(requested, capacity))
                    guard source.frameLength > 0 else { throw PlaylistError.incompleteAudio }
                    state.pointee = .haveData
                    return source
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw MergeError.cannotConvert }
            if converted.frameLength > 0 {
                try output.write(from: converted)
                written += AVAudioFramePosition(converted.frameLength)
            }
            if status == .endOfStream {
                guard written > 0 else { throw PlaylistError.incompleteAudio }
                return written
            }
            guard converted.frameLength > 0 else { throw PlaylistError.incompleteAudio }
        }
    }
}
