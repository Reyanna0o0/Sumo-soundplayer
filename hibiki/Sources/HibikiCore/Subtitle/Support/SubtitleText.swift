import Foundation

/// 字幕文本的清理工具：去标签、解实体、统一换行。
///
/// 设计原则：**解析时只保留纯文本**，样式（斜体、字号、位置）由我们自己的渲染层决定。
/// 这样 SRT 里的 `{\an8}`、VTT 里的 `<c.yellow>`、ASS 里的 `{\pos(1,2)}` 都不会污染显示。
enum SubtitleText {

    /// 统一换行符，去掉 UTF-8 BOM。
    static func normalizeNewlines(_ input: String) -> String {
        var s = input
        if s.hasPrefix("\u{FEFF}") {
            s.removeFirst()
        }
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        return s
    }

    /// 换行成行数组
    static func lines(_ input: String) -> [String] {
        normalizeNewlines(input).components(separatedBy: "\n")
    }

    /// 去掉 SRT / ASS 的 `{...}` 覆写标签
    static func stripBraceTags(_ input: String) -> String {
        guard input.contains("{") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var depth = 0
        for ch in input {
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                out.append(ch)
            }
        }
        return out
    }

    /// 去掉尖括号标签（HTML / VTT），但保留内容文字
    ///
    /// `<i>斜体</i>` → `斜体`；`<v 张三>台词` → `台词`（说话人另行提取）
    static func stripAngleTags(_ input: String) -> String {
        guard input.contains("<") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var inside = false
        for ch in input {
            if ch == "<" {
                inside = true
            } else if ch == ">" {
                inside = false
            } else if !inside {
                out.append(ch)
            }
        }
        return out
    }

    /// 解 HTML 实体（VTT 用得多）
    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var s = input
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", "\u{00A0}"), ("&lrm;", ""), ("&rlm;", "")
        ]
        for (from, to) in map {
            s = s.replacingOccurrences(of: from, with: to)
        }
        // 数字实体 &#123; / &#x1F600;
        s = decodeNumericEntities(s)
        return s
    }

    static func decodeNumericEntities(_ input: String) -> String {
        guard input.contains("&#") else { return input }
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "&",
               let semi = input[i...].firstIndex(of: ";"),
               input.index(i, offsetBy: 2) < semi,
               input[input.index(after: i)] == "#" {
                let body = input[input.index(i, offsetBy: 2)..<semi]
                var scalarValue: UInt32?
                if body.first == "x" || body.first == "X" {
                    scalarValue = UInt32(body.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(body, radix: 10)
                }
                if let v = scalarValue, let scalar = Unicode.Scalar(v) {
                    result.append(Character(scalar))
                    i = input.index(after: semi)
                    continue
                }
            }
            result.append(input[i])
            i = input.index(after: i)
        }
        return result
    }

    /// ASS 的 `\N` / `\n` 转换成真实换行
    static func convertAssNewlines(_ input: String) -> String {
        input
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
    }

    /// 多行文本合成一条：保留换行，去掉每行首尾空白，去掉空行
    static func joinTrimmed(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 一行内的通用清洗（不处理换行）
    static func cleanInline(_ raw: String) -> String {
        var s = raw
        s = stripBraceTags(s)
        s = stripAngleTags(s)
        s = decodeEntities(s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 完整的字幕正文清洗
    static func cleanBlock(_ raw: String) -> String {
        // A line break is structure, not styling: preserve it before removing
        // HTML tags so bilingual text does not become one concatenated sentence.
        let lines = raw.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
        let cleaned = lines.map { cleanInline($0) }
        return joinTrimmed(cleaned)
    }
}
