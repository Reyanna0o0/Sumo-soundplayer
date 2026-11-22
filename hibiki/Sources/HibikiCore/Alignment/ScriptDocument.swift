import Foundation

/// Source text and optional PDF provenance. Geometry uses points with a page's
/// top-left corner as the origin. Plain text never acquires invented geometry.
public struct ScriptDocument: Equatable, Codable, Sendable {
    public var lines: [ScriptTextLine]
    /// Confirmed page-edge decoration only, retained for provenance review.
    /// It never enters section parsing or persisted subtitle text.
    public var excludedLines: [ScriptTextLine]
    public init(lines: [ScriptTextLine], excludedLines: [ScriptTextLine] = []) {
        self.lines = lines; self.excludedLines = excludedLines
    }
    public init(text: String) {
        excludedLines = []
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").enumerated().map { ScriptTextLine(text: $0.element, sourceLineIndex: $0.offset) }
    }
    public var text: String { lines.map(\.text).joined(separator: "\n") }

    private enum CodingKeys: String, CodingKey { case lines, excludedLines }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lines = try values.decode([ScriptTextLine].self, forKey: .lines)
        excludedLines = try values.decodeIfPresent([ScriptTextLine].self, forKey: .excludedLines) ?? []
    }
}

public struct ScriptSourceRange: Equatable, Codable, Sendable {
    /// UTF-16 range in the original PDF page string, before reordering.
    public var start: Int
    public var length: Int
    public init(start: Int, length: Int) { self.start = start; self.length = length }
}

public struct ScriptTextLine: Equatable, Codable, Sendable {
    public var text: String
    public var layout: ScriptLineLayout?
    public var sourceLineIndex: Int?
    public var sourceRanges: [ScriptSourceRange]
    public var sourceRangeStart: Int? { sourceRanges.count == 1 ? sourceRanges[0].start : nil }
    public var sourceRangeLength: Int? { sourceRanges.count == 1 ? sourceRanges[0].length : nil }
    public init(text: String, layout: ScriptLineLayout? = nil, sourceLineIndex: Int? = nil,
                sourceRangeStart: Int? = nil, sourceRangeLength: Int? = nil,
                sourceRanges: [ScriptSourceRange] = []) {
        self.text = text; self.layout = layout; self.sourceLineIndex = sourceLineIndex
        if sourceRanges.isEmpty, let start = sourceRangeStart, let length = sourceRangeLength {
            self.sourceRanges = [ScriptSourceRange(start: start, length: length)]
        } else { self.sourceRanges = sourceRanges }
    }
}

public struct ScriptLineLayout: Equatable, Codable, Sendable {
    public var pageIndex: Int
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double
    public var pageWidth: Double
    public var pageHeight: Double
    public var fontName: String?
    public var fontSize: Double?
    /// The extractor confirmed horizontal reading order and usable coordinates.
    public var isReliable: Bool
    public init(pageIndex: Int, left: Double, top: Double, width: Double, height: Double,
                pageWidth: Double, pageHeight: Double, fontName: String? = nil,
                fontSize: Double? = nil, isReliable: Bool) {
        self.pageIndex = pageIndex; self.left = left; self.top = top
        self.width = width; self.height = height; self.pageWidth = pageWidth; self.pageHeight = pageHeight
        self.fontName = fontName; self.fontSize = fontSize; self.isReliable = isReliable
    }
    var isUsable: Bool {
        isReliable && pageIndex >= 0 && [left, top, width, height, pageWidth, pageHeight].allSatisfy(\.isFinite)
            && left >= 0 && top >= 0 && width > 0 && height > 0 && pageWidth > 0 && pageHeight > 0
            && left + width <= pageWidth + 1 && top + height <= pageHeight + 1
    }
}

public struct ScriptBilingualDecision: Equatable, Codable, Sendable {
    public enum Method: String, Codable, Sendable { case text, localLayout, unresolved }
    public enum Reason: String, Codable, Sendable {
        case incompleteTiming, missingReliableLayout, crossPage, uncertainLanguage
        case indistinguishableRoles, insufficientAnchors, conflictingPattern, ambiguousBoundary
    }
    public enum Feature: String, Codable, Sendable { case fontName, fontSize, indentation }
    public var method: Method
    public var reason: Reason?
    /// Indices in this section; inferred pairs never become supporting anchors.
    public var anchorIndices: [Int]
    public var features: [Feature]
    public init(method: Method, reason: Reason? = nil, anchorIndices: [Int] = [], features: [Feature] = []) {
        self.method = method; self.reason = reason; self.anchorIndices = anchorIndices; self.features = features
    }
}
