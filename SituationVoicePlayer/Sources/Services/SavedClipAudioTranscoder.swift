import AVFoundation
import CLame

/// Converts only the saved standalone clip. No player state or original track is involved.
enum SavedClipAudioTranscoder {
    static func writeWAV(from source: URL, to destination: URL,
                         progress: @Sendable (Double) -> Void) throws {
        if try copyPCMToWAV(from: source, to: destination, progress: progress) { return }
        let probe = try AVAudioFile(forReading: source)
        let original = probe.fileFormat.streamDescription.pointee
        let common: AVAudioCommonFormat
        switch probe.fileFormat.commonFormat {
        case .pcmFormatInt16, .pcmFormatInt32, .pcmFormatFloat64: common = probe.fileFormat.commonFormat
        default: common = .pcmFormatFloat32
        }
        let input = try AVAudioFile(forReading: source, commonFormat: common, interleaved: false)
        let bits = original.mFormatID == kAudioFormatLinearPCM && [16, 24, 32, 64].contains(original.mBitsPerChannel)
            ? Int(original.mBitsPerChannel) : 32
        let floating = original.mFormatID != kAudioFormatLinearPCM || original.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: input.processingFormat.channelCount,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: floating,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: common, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384), input.length > 0 else {
            throw SavedClipExportError.invalidAudio
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, input.length - input.framePosition)))
            guard buffer.frameLength > 0 else { throw SavedClipExportError.invalidAudio }
            try output.write(from: buffer)
            progress(Double(input.framePosition) / Double(input.length))
        }
    }

    /// Copy PCM packets without a converter. Core Audio's converter may pass
    /// Float64 through Float32 even when both file headers say 64-bit.
    private static func copyPCMToWAV(from source: URL, to destination: URL,
                                    progress: @Sendable (Double) -> Void) throws -> Bool {
        var opened: AudioFileID?
        guard AudioFileOpenURL(source as CFURL, .readPermission, 0, &opened) == noErr, let input = opened else {
            throw SavedClipExportError.invalidAudio
        }
        defer { AudioFileClose(input) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(input, kAudioFilePropertyDataFormat, &size, &format) == noErr else {
            throw SavedClipExportError.invalidAudio
        }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              format.mFramesPerPacket == 1, format.mBytesPerPacket > 0,
              [16,24,32,64].contains(format.mBitsPerChannel),
              format.mBytesPerFrame == format.mChannelsPerFrame * format.mBitsPerChannel / 8 else { return false }
        var total: UInt64 = 0; size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(input, kAudioFilePropertyAudioDataPacketCount, &size, &total) == noErr, total > 0 else {
            throw SavedClipExportError.invalidAudio
        }
        let bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        format.mFormatFlags &= ~kAudioFormatFlagIsBigEndian
        var created: AudioFileID?
        guard AudioFileCreateWithURL(destination as CFURL, kAudioFileWAVEType, &format, [], &created) == noErr,
              let output = created else { throw SavedClipExportError.cannotWrite }
        var didClose = false
        defer { if !didClose { AudioFileClose(output) } }
        let bytesPerSample = Int(format.mBitsPerChannel / 8)
        var bytes = [UInt8](repeating: 0, count: 16_384 * Int(format.mBytesPerPacket))
        var position: UInt64 = 0
        while position < total {
            try Task.checkCancellation()
            var packets = UInt32(min(16_384, total - position)), byteCount = UInt32(bytes.count)
            guard AudioFileReadPacketData(input, false, &byteCount, nil, Int64(position), &packets, &bytes) == noErr,
                  packets > 0, byteCount == packets * format.mBytesPerPacket else { throw SavedClipExportError.invalidAudio }
            if bigEndian {
                for offset in stride(from: 0, to: Int(byteCount), by: bytesPerSample) {
                    bytes[offset..<(offset + bytesPerSample)].reverse()
                }
            }
            let read = packets
            let status = AudioFileWritePackets(output, false, byteCount, nil, Int64(position), &packets, bytes)
            guard status == noErr, packets == read else {
                if status == -34 { throw SavedClipExportError.insufficientSpace }
                throw SavedClipExportError.cannotWrite
            }
            position += UInt64(packets); progress(Double(position) / Double(total))
        }
        let closeStatus = AudioFileClose(output); didClose = true
        guard closeStatus == noErr else {
            if closeStatus == -34 { throw SavedClipExportError.insufficientSpace }
            throw SavedClipExportError.cannotWrite
        }
        return true
    }

    static func writeMP3(from source: URL, to destination: URL,
                         progress: @Sendable (Double) -> Void) throws {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let channels = input.processingFormat.channelCount
        guard (1...2).contains(channels) else { throw SavedClipExportError.unsupportedChannels }
        guard input.length > 0, let encoder = lame_init() else { throw SavedClipExportError.invalidAudio }
        defer { lame_close(encoder) }
        let rate = input.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, rate <= Double(Int32.max) else { throw SavedClipExportError.invalidAudio }
        let supportedRates = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        let outputRate = supportedRates.min(by: { abs(Double($0) - rate) < abs(Double($1) - rate) }) ?? 44100
        let settings = [lame_set_in_samplerate(encoder, Int32(rate)),
                        lame_set_out_samplerate(encoder, Int32(outputRate)),
                        lame_set_num_channels(encoder, Int32(channels)),
                        lame_set_mode(encoder, channels == 1 ? MONO : JOINT_STEREO),
                        lame_set_VBR(encoder, vbr_default), lame_set_VBR_quality(encoder, 2),
                        lame_set_quality(encoder, 2), lame_set_findReplayGain(encoder, 0),
                        lame_set_bWriteVbrTag(encoder, 1), lame_set_num_samples(encoder, UInt(input.length))]
        guard settings.allSatisfy({ $0 == 0 }) else { throw SavedClipExportError.encodingFailed }
        lame_set_write_id3tag_automatic(encoder, 0)
        guard lame_init_params(encoder) >= 0 else { throw SavedClipExportError.encodingFailed }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SavedClipExportError.cannotWrite
        }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
            throw SavedClipExportError.invalidAudio
        }
        var encoded = [UInt8](repeating: 0, count: 32_768)
        func write(_ count: Int32) throws {
            guard count >= 0, count <= encoded.count else { throw SavedClipExportError.encodingFailed }
            if count > 0 { try file.write(contentsOf: Data(encoded.prefix(Int(count)))) }
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, input.length - input.framePosition)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { throw SavedClipExportError.invalidAudio }
            let count = lame_encode_buffer_ieee_float(encoder, data[0], data[channels == 1 ? 0 : 1],
                                                     Int32(buffer.frameLength), &encoded, Int32(encoded.count))
            try write(count)
            progress(Double(input.framePosition) / Double(input.length))
        }
        try Task.checkCancellation()
        let count = lame_encode_flush(encoder, &encoded, Int32(encoded.count))
        try write(count)
        // Replace LAME's reserved first frame with duration, delay and padding
        // metadata, so players can seek and trim MP3 encoder padding correctly.
        let tagSize = lame_get_lametag_frame(encoder, &encoded, encoded.count)
        guard tagSize > 0, tagSize <= encoded.count else { throw SavedClipExportError.encodingFailed }
        try file.seek(toOffset: 0)
        try file.write(contentsOf: Data(encoded.prefix(tagSize)))
        try file.synchronize()
    }
}
