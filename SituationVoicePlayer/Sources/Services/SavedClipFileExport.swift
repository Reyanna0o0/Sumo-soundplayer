import Foundation
import AVFoundation

enum SavedClipExportFormat: String, CaseIterable, Identifiable {
    case mp3, wav, caf
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var detail: String {
        switch self {
        case .mp3: return InterfaceLocalization.text("高音质，文件较小，适合分享。")
        case .wav: return InterfaceLocalization.text("PCM 音频，保留采样率与精度，文件较大。")
        case .caf: return InterfaceLocalization.text("原样导出已保存的摘选。")
        }
    }
}

enum SavedClipExportError: LocalizedError {
    case missingClip, invalidAudio, unsupportedChannels, encodingFailed, cannotWrite, insufficientSpace, tooLarge
    var errorDescription: String? {
        switch self {
        case .missingClip: return InterfaceLocalization.text("找不到这份保存的音频，无法导出。原曲不会被重新截取。")
        case .invalidAudio: return InterfaceLocalization.text("无法完整读取这份摘选。原文件已保留。")
        case .unsupportedChannels: return InterfaceLocalization.text("这份摘选超过两个声道，请选择 WAV 或 CAF，避免丢失声道。")
        case .encodingFailed: return InterfaceLocalization.text("音频转换未完成，请重试或选择其他格式。原摘选已保留。")
        case .cannotWrite: return InterfaceLocalization.text("无法写入导出副本，请检查可用空间后重试。")
        case .insufficientSpace: return InterfaceLocalization.text("可用空间不足，无法生成导出副本。请腾出空间后重试，原摘选已保留。")
        case .tooLarge: return InterfaceLocalization.text("这份音频超过 WAV 文件大小限制，请选择 MP3 或 CAF。")
        }
    }
}

/// 只拥有本次导出的临时目录。系统保存/分享结束后释放，库内原件不在清理范围。
final class SavedClipFileExport: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let directory: URL

    private init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    deinit { removeTemporaryCopy() }

    /// UIKit may retain a dismissed controller; release only this completed copy immediately.
    func removeTemporaryCopy() { try? FileManager.default.removeItem(at: directory) }

    static func prepare(entry: SavedPlaylistEntry, clipsDirectory: URL,
                        temporaryRoot: URL = FileManager.default.temporaryDirectory,
                        format: SavedClipExportFormat = .mp3,
                        availableBytes: Int64? = nil,
                        progress: @Sendable (Double) -> Void = { _ in }) throws -> SavedClipFileExport {
        guard let filename = entry.clipFilename, !filename.isEmpty,
              filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains("/"), !filename.contains("\\"),
              filename.lowercased().hasSuffix(".caf") else { throw SavedClipExportError.missingClip }
        let source = clipsDirectory.appendingPathComponent(filename)
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw SavedClipExportError.missingClip
        }
        try Task.checkCancellation()
        let audio = try AVAudioFile(forReading: source)
        let rate = audio.processingFormat.sampleRate
        guard audio.length > 0, rate.isFinite, rate > 0 else { throw SavedClipExportError.invalidAudio }
        let bytesPerFrame = max(try storedPCMBytesPerFrame(source) ?? audio.fileFormat.streamDescription.pointee.mBytesPerFrame,
                                audio.processingFormat.channelCount * 4)
        let estimated: Double
        switch format {
        case .caf: estimated = Double((try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
        case .wav: estimated = Double(audio.length) * Double(bytesPerFrame) + 4096
        case .mp3: estimated = Double(audio.length) / rate * 40_000 + 131_072
        }
        if format == .wav, estimated >= Double(UInt32.max) { throw SavedClipExportError.tooLarge }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let space = try temporaryRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let free = availableBytes ?? space.volumeAvailableCapacityForImportantUsage ?? space.volumeAvailableCapacity.map(Int64.init),
           Double(free) < estimated + 10_485_760 { throw SavedClipExportError.insufficientSpace }
        let directory = temporaryRoot.appendingPathComponent("SimoClipExports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(exportName(entry)).appendingPathExtension(format.rawValue)
        let export = SavedClipFileExport(url: destination, directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress(0)
        do {
            switch format {
            case .caf: try FileManager.default.copyItem(at: source, to: destination)
            case .wav: try SavedClipAudioTranscoder.writeWAV(from: source, to: destination, progress: progress)
            case .mp3: try SavedClipAudioTranscoder.writeMP3(from: source, to: destination, progress: progress)
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
            throw SavedClipExportError.insufficientSpace
        }
        try Task.checkCancellation()
        progress(1)
        return export
    }

    /// AVAudioFile can report an unspecified file format for Float64 PCM on
    /// iOS. Read the stored ASBD so space/RIFF limits include all original bytes.
    private static func storedPCMBytesPerFrame(_ source: URL) throws -> UInt32? {
        var opened: AudioFileID?
        guard AudioFileOpenURL(source as CFURL, .readPermission, 0, &opened) == noErr,
              let file = opened else { throw SavedClipExportError.invalidAudio }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr else {
            throw SavedClipExportError.invalidAudio
        }
        guard format.mFormatID == kAudioFormatLinearPCM else { return nil }
        return max(format.mBytesPerFrame, format.mChannelsPerFrame * ((format.mBitsPerChannel + 7) / 8))
    }

    private static func exportName(_ entry: SavedPlaylistEntry) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:?*\"<>|"))
        let cleaned = entry.title.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var title = ""
        for character in cleaned {
            let next = title + String(character)
            if next.utf8.count > 150 { break }
            title = next
        }
        if title.isEmpty { title = InterfaceLocalization.text("摘选") }
        if !entry.isMerged, let start = entry.startMS, let end = entry.endMS, start >= 0, end > start {
            let from = SubtitleTime.clock(start).replacingOccurrences(of: ":", with: "-")
            let to = SubtitleTime.clock(end).replacingOccurrences(of: ":", with: "-")
            return "\(title) · \(from)–\(to)"
        }
        return InterfaceLocalization.text("\(title) · 拼接")
    }
}
