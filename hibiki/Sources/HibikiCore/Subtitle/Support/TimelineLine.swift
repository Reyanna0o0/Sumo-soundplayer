import Foundation

/// 解析 `00:00:01,000 --> 00:00:04,000` 这种时间行。
///
/// SRT 与 WebVTT 共用；VTT 在时间后面还可能跟 cue settings
/// （`align:start position:10%`），这里单独返回，交给调用方决定是否使用。
enum TimelineLine {
    struct Parsed {
        let startMS: Int
        let endMS: Int
        /// 时间行之后的附加设置（VTT cue settings / 老式 SRT 坐标参数）
        let settings: String
    }

    static func parse(_ line: String) -> Parsed? {
        let arrows = ["-->", "->", "—>", "–>"]
        var arrowRange: Range<String.Index>?
        for arrow in arrows {
            if let r = line.range(of: arrow) {
                arrowRange = r
                break
            }
        }
        guard let arrow = arrowRange else { return nil }

        let left = String(line[line.startIndex..<arrow.lowerBound])
        let right = String(line[arrow.upperBound...])

        guard let startMS = SubtitleTime.parseMilliseconds(firstToken(left)) else { return nil }

        // 右侧 = 结束时间 + 可能的设置
        let rightTrimmed = right.trimmingCharacters(in: .whitespaces)
        let tokens = rightTrimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let firstRight = tokens.first,
              let endMS = SubtitleTime.parseMilliseconds(firstRight)
        else { return nil }

        let settings = tokens.dropFirst().joined(separator: " ")
        return Parsed(startMS: startMS, endMS: endMS, settings: settings)
    }

    private static func firstToken(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first.map(String.init) ?? ""
    }
}
