import Foundation
import AVFoundation
import ImageIO
import UIKit

enum WorkAssetImportError: LocalizedError {
    case unreadableAudio(String), unreadableImage, unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let name): return InterfaceLocalization.text("「\(name)」不是当前可以读取的音频文件。")
        case .unsupportedFile(let name): return InterfaceLocalization.text("暂不能导入「\(name)」。请选择音频、图片、PDF、文字、视频或其他支持的文档。")
        case .unreadableImage: return InterfaceLocalization.text("无法读取这张图片，请换一张图片。")
        }
    }
}

/// 文件只复制进 App 自有目录，不移动、改写用户选择的原文件。
enum WorkAssetImporter {
    static func directory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("WorkAssets", isDirectory: true)
    }

    static func path(for relative: String) -> String? {
        guard let root = try? directory() else { return nil }
        return LibraryPathResolver.assetPath(relative: relative, assetsRoot: root.path)
    }

    static func remove(_ relative: String) {
        guard let path = path(for: relative) else { return }
        let url = URL(fileURLWithPath: path)
        if relative.hasPrefix("Covers/"), url.pathExtension == "jpg" {
            try? FileManager.default.removeItem(at: sourceImageURL(for: url))
        }
        try? FileManager.default.removeItem(at: url)
    }

    static func copyAudio(from source: URL, workID: Int64) throws -> TrackRecord {
        let type = source.pathExtension.lowercased()
        // 与 AudioPlaybackEngine 当前可解码的音频格式一致。
        let supported: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "wave", "aiff", "aif", "flac", "caf"]
        guard supported.contains(type) else {
            throw WorkAssetImportError.unreadableAudio(source.lastPathComponent)
        }
        let relative = "Audio/\(UUID().uuidString).\(type)"
        let destination = try destination(for: relative)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        try readSelectedFile(source) { coordinated in
            try FileManager.default.copyItem(at: coordinated, to: destination)
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: destination) }
        catch { throw WorkAssetImportError.unreadableAudio(source.lastPathComponent) }
        let rate = file.processingFormat.sampleRate
        guard file.length > 0, rate.isFinite, rate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else {
            throw WorkAssetImportError.unreadableAudio(source.lastPathComponent)
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { throw WorkAssetImportError.unreadableAudio(source.lastPathComponent) }
        let values = try destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        committed = true
        return TrackRecord(workID: workID, fileName: source.lastPathComponent, filePath: destination.path,
                           fileType: type, durationMS: Int(Double(file.length) * 1000 / rate),
                           fileSize: values.fileSize.map { Int64($0) }, fileMtime: values.contentModificationDate,
                           assetRelativePath: relative)
    }

    static func copyAttachment(from url: URL, workID: Int64) throws -> WorkAttachmentRecord {
        guard let kind = WorkAttachmentFinder.kind(forExtension: url.pathExtension) else {
            throw WorkAssetImportError.unsupportedFile(url.lastPathComponent)
        }
        let path = "Attachments/\(UUID().uuidString).\(url.pathExtension.lowercased())"
        let target = try destination(for: path)
        do {
            try readSelectedFile(url) { coordinated in
                let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
                try FileManager.default.copyItem(at: coordinated, to: target)
            }
            let bytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let file = WorkAttachment(relativePath: url.lastPathComponent, kind: kind, byteCount: Int64(bytes))
            return WorkAttachmentRecord(workID: workID, attachment: file, assetRelativePath: path)
        } catch {
            remove(path)
            throw error
        }
    }

    static func copyCover(from url: URL) throws -> String {
        try readSelectedFile(url) { coordinated in
            guard let source = CGImageSourceCreateWithURL(coordinated as CFURL, nil) else {
                throw WorkAssetImportError.unreadableImage
            }
            return try saveCover(source)
        }
    }

    static func copyCover(data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WorkAssetImportError.unreadableImage
        }
        return try saveCover(source)
    }

    private static func saveCover(_ source: CGImageSource) throws -> String {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.92) else {
            throw WorkAssetImportError.unreadableImage
        }
        let relative = "Covers/\(UUID().uuidString).jpg"
        let destination = try destination(for: relative)
        do { try data.write(to: destination, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return relative
    }

    private static func sourceImageURL(for cover: URL) -> URL {
        cover.deletingPathExtension().appendingPathExtension("source.jpg")
    }

    static func originalImageForCropping(at path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        guard let root = try? directory(), url.deletingLastPathComponent().standardizedFileURL.path == root.appendingPathComponent("Covers").standardizedFileURL.path else { return url }
        let original = sourceImageURL(for: url)
        return FileManager.default.fileExists(atPath: original.path) ? original : url
    }

    static func croppedCover(from relative: String, rect: CGRect, preserveOriginal: Bool = true) throws -> String {
        guard let path = path(for: relative), let image = UIImage(contentsOfFile: path),
              rect.width > 0, rect.height > 0 else { throw WorkAssetImportError.unreadableImage }
        // Render the preview's aspect ratio: square for avatars, 4:3 for covers.
        // A multiple of four preserves integral dimensions for both formats.
        let width = max(4, (rect.width / 4).rounded() * 4)
        let size = CGSize(width: width, height: max(1, (width * rect.height / rect.width).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let data = renderer.jpegData(withCompressionQuality: 0.94) { _ in
            let factor = width / rect.width
            image.draw(in: CGRect(x: -rect.minX * factor, y: -rect.minY * factor,
                                  width: image.size.width * factor, height: image.size.height * factor))
        }
        let result = "Covers/\(UUID().uuidString).jpg"
        let output = try destination(for: result)
        do {
            if preserveOriginal {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: sourceImageURL(for: output))
            }
            try data.write(to: output, options: .atomic)
        } catch { remove(result); throw error }
        return result
    }

    private static func destination(for relative: String) throws -> URL {
        let directory = try directory()
        guard let path = LibraryPathResolver.assetPath(relative: relative, assetsRoot: directory.path) else {
            throw LibraryEditingError.invalidAssetPath
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private static func readSelectedFile<T>(_ url: URL, body: (URL) throws -> T) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try body(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}
