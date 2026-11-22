import Foundation

/// 不使用每次读库都会改变的 UUID，也不依赖未打轴台词共同的零起点。
public struct ScriptReadingPosition: Codable, Equatable, Sendable {
    public let index: Int
    public let fraction: Double
    private let current: ReadingCueText
    private let previous: ReadingCueText?
    private let next: ReadingCueText?

    public init?(cues: [SubtitleCue], index: Int, fraction: Double = 0) {
        guard cues.indices.contains(index) else { return nil }
        self.index = index
        self.fraction = readingUnitFraction(fraction)
        current = ReadingCueText(cues[index])
        previous = index > 0 ? ReadingCueText(cues[index - 1]) : nil
        next = index + 1 < cues.count ? ReadingCueText(cues[index + 1]) : nil
    }

    var isValid: Bool { index >= 0 && fraction.isFinite && (0...1).contains(fraction) }

    /// 优先找原句，重复句用上下文和原来的距离区分；原句被删改时靠邻句回到附近。
    public func resolvedIndex(in cues: [SubtitleCue]) -> Int? {
        guard !cues.isEmpty, isValid else { return nil }
        let lines = cues.map(ReadingCueText.init)
        let fallback = min(index, lines.count - 1)
        func contextScore(_ candidate: Int) -> Int {
            var score = 0
            if candidate > 0, let previous, previous.matches(lines[candidate - 1]) { score += 1 }
            if candidate + 1 < lines.count, let next, next.matches(lines[candidate + 1]) { score += 1 }
            return score
        }
        func best(_ candidates: [Int], targetMatches: Bool) -> Int? {
            candidates.min { left, right in
                let ls = contextScore(left) + (targetMatches && current == lines[left] ? 4 : 0)
                let rs = contextScore(right) + (targetMatches && current == lines[right] ? 4 : 0)
                if ls != rs { return ls > rs }
                // 与钳住后的原位置比较，避免损坏记录中的极端整数做减法溢出。
                let ld = abs(left - fallback), rd = abs(right - fallback)
                return ld == rd ? left < right : ld < rd
            }
        }
        let matches = lines.indices.filter { current.matches(lines[$0]) }
        if let matched = best(matches, targetMatches: true) { return matched }
        let nearby = lines.indices.filter { contextScore($0) > 0 }
        return best(nearby, targetMatches: false) ?? fallback
    }
}

private struct ReadingCueText: Codable, Equatable, Sendable {
    let text: String
    let translation: String

    init(_ cue: SubtitleCue) {
        text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
        translation = (cue.translatedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(_ other: Self) -> Bool {
        if !text.isEmpty { return text == other.text }
        return other.text.isEmpty && translation == other.translation
    }
}

/// 点的方向由 PDF 页面坐标定义；x/y 是页面边界内的比例，转屏后仍能寻址同一处。
public struct PDFReadingPosition: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let x: Double
    public let y: Double

    public init(pageIndex: Int, x: Double, y: Double) {
        self.pageIndex = max(0, pageIndex)
        self.x = readingUnitFraction(x)
        self.y = readingUnitFraction(y)
    }

    var isValid: Bool {
        pageIndex >= 0 && x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
    }

    public func resolvedPageIndex(pageCount: Int) -> Int? {
        guard pageCount > 0, isValid else { return nil }
        return min(pageIndex, pageCount - 1)
    }
}

/// TextKit 的文字位置使用 UTF-16；不存会随字号与横竖屏变化的整页像素偏移。
public struct TextReadingPosition: Codable, Equatable, Sendable {
    public let utf16Offset: Int

    public init(utf16Offset: Int) { self.utf16Offset = max(0, utf16Offset) }

    public func clampedUTF16Offset(in text: String) -> Int {
        let string = text as NSString
        guard string.length > 0 else { return 0 }
        let offset = min(max(0, utf16Offset), string.length - 1)
        // Emoji、组合音标及代理对都回到完整字符的起点。
        return string.rangeOfComposedCharacterSequence(at: offset).location
    }
}

private func readingUnitFraction(_ value: Double) -> Double {
    value.isFinite ? min(1, max(0, value)) : 0
}
