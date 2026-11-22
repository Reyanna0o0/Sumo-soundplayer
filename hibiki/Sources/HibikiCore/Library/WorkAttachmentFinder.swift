import Foundation

public enum WorkAttachmentKind: String, CaseIterable, Sendable {
    case image, pdf, text, video, document

    public var title: String {
        switch self {
        case .image: return InterfaceLocalization.text("图片")
        case .pdf: return "PDF"
        case .text: return InterfaceLocalization.text("文字")
        case .video: return InterfaceLocalization.text("视频")
        case .document: return InterfaceLocalization.text("其他文档")
        }
    }

    public var iconName: String {
        switch self {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .text: return "doc.text"
        case .video: return "play.rectangle"
        case .document: return "doc"
        }
    }
}

/// 目录附件使用相对路径，独立于音轨和字幕记录；打开作品时重新枚举，旧作品也能显示。
public struct WorkAttachment: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let kind: WorkAttachmentKind
    public let byteCount: Int64
    public var fileName: String { (relativePath as NSString).lastPathComponent }
    public var fileExtension: String { (relativePath as NSString).pathExtension.lowercased() }

    public init(relativePath: String, kind: WorkAttachmentKind, byteCount: Int64) {
        self.relativePath = relativePath
        self.kind = kind
        self.byteCount = byteCount
    }
}

public enum WorkAttachmentFinder {
    /// 扩展名只决定是否列出，系统能否预览在打开时检查，不能据此保证解码支持。
    public static func kind(forExtension ext: String) -> WorkAttachmentKind? {
        let ext = ext.lowercased()
        if MediaExtensions.image.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ["txt", "md", "markdown"].contains(ext) { return .text }
        if MediaExtensions.video.contains(ext) { return .video }
        if MediaExtensions.document.contains(ext) { return .document }
        return nil
    }

    public static func find(in directory: URL) throws -> [WorkAttachment] {
        // 枚举器会把 /var 等系统路径别名展开成 /private/var，前缀必须采用同一种规范。
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName, userInfo: [NSURLErrorKey: directory])
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: directory]) }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var attachments: [WorkAttachment] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            let path = url.standardizedFileURL.path
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  let kind = kind(forExtension: url.pathExtension), path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            attachments.append(WorkAttachment(relativePath: relative, kind: kind,
                                              byteCount: Int64(values.fileSize ?? 0)))
        }
        if let enumerationError { throw enumerationError }
        return attachments.sorted { NaturalSort.compare($0.relativePath, $1.relativePath) }
    }

    /// 旧自动扫描把单一 wav/、mp3/ 等格式目录当成作品；只在明确允许时兼容其同级附件。
    public static func isLegacyFormatFolder(_ relativePath: String) -> Bool {
        !relativePath.contains("/") && MediaExtensions.audio.contains(relativePath.lowercased())
    }

    public static func fileURL(for attachment: WorkAttachment, in directory: URL) -> URL? {
        guard let path = LibraryPathResolver.assetPath(relative: attachment.relativePath, assetsRoot: directory.path) else {
            return nil
        }
        let url = URL(fileURLWithPath: path)
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return url
    }
}

public enum WorkAttachmentTextEncoding: String, CaseIterable, Identifiable, Sendable {
    case automatic, utf8, utf16, shiftJIS, gb18030, big5
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return InterfaceLocalization.text("自动识别")
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .shiftJIS: return InterfaceLocalization.text("Shift-JIS（日文）")
        case .gb18030: return InterfaceLocalization.text("GB18030 / GBK（简体）")
        case .big5: return InterfaceLocalization.text("Big5（繁体）")
        }
    }

    public func decode(_ data: Data) -> String? {
        if data.isEmpty { return "" }
        switch self {
        case .automatic: return SubtitleTextDecoder.decode(data: data)
        case .utf8: return String(data: data, encoding: .utf8)
        case .utf16: return String(data: data, encoding: .utf16)
        case .shiftJIS: return String(data: data, encoding: .shiftJIS)
        case .gb18030: return String(data: data, encoding: SubtitleTextDecoder.gb18030)
        case .big5:
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String(data: data, encoding: String.Encoding(rawValue: encoding))
        }
    }
}

public enum WorkAttachmentTextReader {
    /// 限制读取量，避免超大文本占满内存；调用方在后台读取，界面使用 UITextView 按需排版。
    public static let maximumByteCount = 8 * 1024 * 1024

    public enum Failure: LocalizedError {
        case tooLarge, invalidEncoding
        public var errorDescription: String? {
            switch self {
            case .tooLarge: return InterfaceLocalization.text("文字文件超过 8 MB，请使用分享按钮在其他阅读器中打开。")
            case .invalidEncoding: return InterfaceLocalization.text("无法用这个编码读取，请换一种文字编码。")
            }
        }
    }

    public static func read(from url: URL, encoding: WorkAttachmentTextEncoding) throws -> String {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, size > maximumByteCount { throw Failure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumByteCount + 1) ?? Data()
        try Task.checkCancellation()
        guard data.count <= maximumByteCount else { throw Failure.tooLarge }
        guard let text = encoding.decode(data) else { throw Failure.invalidEncoding }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
    }
}
