import Foundation
#if canImport(PDFKit)
import PDFKit

/// 从 PDF 抽文字。
///
/// 扫描件（图片 PDF）取不到文字，会明确报错，而不是静默返回空字符串。
public enum PDFTextExtractor {

    public enum Failure: LocalizedError {
        case unreadable
        case empty
        case scanned

        public var errorDescription: String? {
            switch self {
            case .unreadable: return InterfaceLocalization.text("无法打开 PDF")
            case .empty: return InterfaceLocalization.text("PDF 里没有文字")
            case .scanned: return InterfaceLocalization.text("这个 PDF 是扫描图片，需要 OCR")
            }
        }
    }

    public static func extract(url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }

        var pages: [String] = []
        var emptyPages = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyPages += 1
            } else {
                pages.append(text)
            }
        }

        if pages.isEmpty {
            throw document.pageCount > 0 ? Failure.scanned : Failure.empty
        }
        if document.pageCount > 2, emptyPages > document.pageCount / 2 {
            throw Failure.scanned
        }
        return pages.joined(separator: "\n")
    }
}
#endif
