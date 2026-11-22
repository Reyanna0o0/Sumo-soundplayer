import Foundation
import PDFKit

/// 从台本文件读取文字；PDF 同时保留页内位置和原始字符范围。
/// 读不到可选文字的扫描件仍提示 OCR，不制造正文。
enum ScriptExtractor {

    enum Failure: LocalizedError {
        case unreadable
        case emptyPDF
        case scannedPDF

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return InterfaceLocalization.text("无法读取这个文件")
            case .emptyPDF:
                return InterfaceLocalization.text("PDF 里没有文字")
            case .scannedPDF:
                return InterfaceLocalization.text("这个 PDF 是扫描图片，需要 OCR。先做识别，或换一份带文字的台本。")
            }
        }
    }

    static func readForImport(_ url: URL, name: String, tracks: [TrackRecord],
                              workRoot: String? = nil, lease: WorkAttachmentDirectoryLease? = nil) async throws -> WorkScriptMatching {
        try await Task.detached(priority: .userInitiated) {
            defer { withExtendedLifetime(lease) {} }
            let candidates = workRoot.map { AutomaticPDFScripts.scope(tracks, for: url, workRoot: $0, fileName: name) }
                ?? AutomaticPDFScripts.contentScope(tracks, fileName: name)
            let result = try WorkScriptMatching(document: extractDocument(from: url), fileName: name, candidates: candidates)
            guard !result.sections.isEmpty else { throw ScriptImportFailure.emptySection }
            return result
        }.value
    }

    /// 兼容只需要纯文本的调用者；导入路径使用 extractDocument 保留版面。
    static func extractText(from url: URL) throws -> String {
        try extractDocument(from: url).text
    }

    static func extractDocument(from url: URL) throws -> ScriptDocument {
        let ext = url.pathExtension.lowercased()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        if ext == "pdf" {
            return try extractPDFDocument(url: url)
        }

        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        guard let text = SubtitleTextDecoder.decode(data: data) else { throw Failure.unreadable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyPDF
        }
        return ScriptDocument(text: text)
    }

    private static func extractPDFDocument(url: URL) throws -> ScriptDocument {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }

        var readable: [(page: PDFPage, text: String, index: Int)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                readable.append((page, text, index))
            }
        }

        if readable.isEmpty {
            // 有可能是扫描件
            let hasImages = (0..<document.pageCount).contains { index in
                guard let page = document.page(at: index) else { return false }
                return !(page.annotations.isEmpty) || page.string == nil
            }
            throw hasImages ? Failure.scannedPDF : Failure.emptyPDF
        }
        var pages = readable.map { page, text, index in
            PDFScriptTextOrder.extract(on: page, original: text, pageIndex: index)
        }
        // Only exact repetitions in the same isolated top margin count as a
        // running header. A one-page title remains independent source text.
        var headers: [(page: Int, line: ScriptTextLine)] = []
        for (index, extraction) in pages.enumerated() where readable[index].page.rotation % 360 == 0 {
            let visible = extraction.lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            let sizes = visible.compactMap { $0.layout?.fontSize }.sorted()
            guard !sizes.isEmpty else { continue }
            let bodySize = sizes[sizes.count / 2]
            for line in visible {
                guard let layout = line.layout, let size = layout.fontSize,
                      layout.width > 0, layout.height > 0, layout.top >= 0,
                      layout.top + layout.height < layout.pageHeight * 0.08,
                      layout.height < bodySize * 1.4, size < bodySize * 0.92,
                      line.sourceRanges.count == 1 else { continue }
                let other = visible.filter { $0.sourceRanges != line.sourceRanges }.compactMap(\.layout)
                guard let next = other.map(\.top).min(), next - layout.top - layout.height > layout.height * 2 else { continue }
                headers.append((index, line))
            }
        }
        var headerRanges: [Int: [ScriptSourceRange]] = [:]
        for candidate in headers {
            let position = candidate.line.layout!
            let repeated = headers.contains { other in
                guard other.page != candidate.page, other.line.text == candidate.line.text,
                      let otherPosition = other.line.layout else { return false }
                return abs(otherPosition.left - position.left) < 2 && abs(otherPosition.top - position.top) < 2
                    && abs(otherPosition.pageWidth - position.pageWidth) < 2
                    && abs(otherPosition.pageHeight - position.pageHeight) < 2
                    && otherPosition.fontName == position.fontName
                    && abs((otherPosition.fontSize ?? 0) - (position.fontSize ?? 0)) < 0.01
            }
            if repeated { headerRanges[candidate.page, default: []].append(contentsOf: candidate.line.sourceRanges) }
        }
        for (index, ranges) in headerRanges {
            let (page, text, pageIndex) = readable[index]
            pages[index] = PDFScriptTextOrder.extract(on: page, original: text, pageIndex: pageIndex, excludingRanges: ranges)
        }
        // PDFKit 在不同 iOS 版本上可能把页眉排在台词中间。只剔除跨页重复、
        // 明确以联络/广告标签开头且包含网址或联络号码的整行，保留有网址的对白。
        let marker = #"(?i)^(?:有[偿償](?:包|订阅|訂閱)|防[失断斷][联聯]|更新目[录錄]|(?:联系|聯繫)(?:方式|我们|我們)|(?:公式|official)\s*(?:site|サイト))[^\n]*(?:https?://|(?:qq\s*[群號号]?|[群组組][号號])\s*[:：]?\s*[0-9]{5,})"#
        var pageCounts: [String: Int] = [:]
        for page in pages {
            let labels = Set(page.lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter {
                $0.range(of: marker, options: .regularExpression) != nil
            })
            for label in labels { pageCounts[label, default: 0] += 1 }
        }
        // 页间不添加空段或时间；跨页正文仍由原始顺序和解析器处理。
        let isRepeatedLabel = { (line: ScriptTextLine) in
            pageCounts[line.text.trimmingCharacters(in: .whitespaces), default: 0] >= 2
        }
        return ScriptDocument(lines: pages.flatMap { $0.lines.filter { !isRepeatedLabel($0) } },
                              excludedLines: pages.flatMap { $0.excludedLines + $0.lines.filter(isRepeatedLabel) })
    }

    /// 台本文件是否值得尝试
    static func looksLikeScript(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let scriptWords = ["台本", "脚本", "script", "セリフ", "台词", "正文", "全文", "シナリオ"]
        let hasWord = scriptWords.contains { lower.contains($0) }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let isText = ["pdf", "txt", "md"].contains(ext)
        return isText && (hasWord || ext == "pdf" || ext == "txt")
    }
}
