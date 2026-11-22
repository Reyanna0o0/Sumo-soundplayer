import Foundation

/// 合集台本里的一段（对应一条音轨）
public struct ScriptSection: Identifiable, Equatable, Sendable {
    public var index: Int
    /// 台本里标注的轨道号（可能没有）
    public var trackNumber: Int?
    /// 段落标题（标记行后面的文字）
    public var title: String
    public var lines: [ScriptLine]

    public var id: Int { index }

    public init(index: Int, trackNumber: Int? = nil, title: String = "", lines: [ScriptLine]) {
        self.index = index
        self.trackNumber = trackNumber
        self.title = title
        self.lines = lines
    }

    public var displayName: String {
        if let trackNumber {
            return title.isEmpty ? "第 \(trackNumber) 轨" : "第 \(trackNumber) 轨 · \(title)"
        }
        return title.isEmpty ? "整份台本" : title
    }
}

/// 把"一份覆盖多条音轨的台本"按轨道标记切开。
///
/// 真实台本长这样（注意 **全角数字**）：
/// ```
/// ■TRACK１ 不能吃青梅竹马做的料理
/// 庵：「哎呀，真的好久不见了呢
/// ```
/// 如果没有标记，就当成"整份台本对应一条音轨"。
public enum ScriptSectioner {

    /// 切分台本
    public static func split(_ text: String) -> [ScriptSection] {
        split(ScriptDocument(text: text))
    }

    public static func split(_ document: ScriptDocument) -> [ScriptSection] {
        let rawLines = document.lines

        var sections: [(trackNumber: Int?, title: String, buffer: [ScriptTextLine])] = []
        var currentBuffer: [ScriptTextLine] = []
        var currentNumber: Int?
        var currentTitle: String = ""
        var foundMarker = false

        for raw in rawLines {
            if let marker = parseMarker(raw.text) {
                // 遇到新标记：把之前的收尾
                if foundMarker || !currentBuffer.isEmpty {
                    sections.append((currentNumber, currentTitle, currentBuffer))
                }
                currentBuffer = []
                currentNumber = marker.number
                currentTitle = marker.title
                foundMarker = true
                continue
            }
            currentBuffer.append(raw)
        }
        if foundMarker || !currentBuffer.isEmpty {
            sections.append((currentNumber, currentTitle, currentBuffer))
        }

        // 解析每一段的台词
        var result: [ScriptSection] = []
        for section in sections {
            let lines = ScriptParser.parseSection(section.buffer)
            guard !lines.isEmpty else { continue }
            result.append(
                ScriptSection(
                    index: result.count,
                    trackNumber: section.trackNumber,
                    title: section.title,
                    lines: lines
                )
            )
        }
        return result
    }

    /// 识别轨道标记行
    /// - Returns: (轨道号, 标题)；不是标记行返回 nil
    public static func parseMarker(_ line: String) -> (number: Int?, title: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 去掉前导符号（■●◆★☆◎▶►※ 等）
        var body = trimmed
        while let first = body.first, "■●◆★☆◎▶►※▽▼-—– ".contains(first) {
            body.removeFirst()
        }
        guard !body.isEmpty else { return nil }

        // TRACK１ / Track 1 / トラック1 / TR.1 / 第1話 / 第1話
        let patterns = [
            "^(?i:track|tr)\\s*[.．]?\\s*([0-9０-９]{1,3})(?![0-9０-９])\\s*[:：]?\\s*(.*)$",
            "^(?:トラック|とらっく)\\s*([0-9０-９]{1,3})(?![0-9０-９])\\s*[:：]?\\s*(.*)$",
            "^第\\s*([0-9０-９]{1,3})\\s*[話话章節节]\\s*[:：]?\\s*(.*)$"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            guard let match = regex.firstMatch(in: body, range: range) else { continue }

            var number: Int?
            if let numberRange = Range(match.range(at: 1), in: body) {
                number = Int(normalizeDigits(String(body[numberRange])))
            }
            var title = ""
            if match.numberOfRanges > 2, let titleRange = Range(match.range(at: 2), in: body) {
                title = String(body[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (number, title)
        }
        return nil
    }

    /// 从音频文件名里读出轨道号：`Tr1_xxx.wav` → 1，`03 xxx.mp3` → 3
    public static func trackNumber(fromFileName fileName: String) -> Int? {
        let base = normalizeDigits((fileName as NSString).deletingPathExtension)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            "^(?i:track|tr|トラック)\\s*[.．]?\\s*([0-9]{1,3})(?![0-9])",
            "^([0-9]{1,3})[\\s._\\-]",
            "^([0-9]{1,3})$",
            "^第([0-9]{1,3})[話话章節节]"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: base, range: NSRange(base.startIndex..<base.endIndex, in: base)),
               let range = Range(match.range(at: 1), in: base) {
                return Int(base[range])
            }
        }
        return nil
    }

    /// 找到与该音轨对应的段落
    public static func section(forTrackNumber number: Int, in sections: [ScriptSection]) -> ScriptSection? {
        let exact = sections.filter { $0.trackNumber == number }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { return nil }
        // 没有标注轨道号时，按顺序对应
        if sections.count > 1, sections.indices.contains(number - 1),
           sections.allSatisfy({ $0.trackNumber == nil }) {
            return sections[number - 1]
        }
        return nil
    }

    /// 全角数字转半角
    static func normalizeDigits(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar.value >= 0xFF10, scalar.value <= 0xFF19 {
                result.append(Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!))
            } else {
                result.append(Character(scalar))
            }
        }
        return result
    }
}
