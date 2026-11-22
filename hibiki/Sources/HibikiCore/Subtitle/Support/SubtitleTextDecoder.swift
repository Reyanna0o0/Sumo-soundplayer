import Foundation

/// 把字幕文件的字节流解码成字符串。
///
/// 天真的 `String(data:encoding:.utf8)` 会毁掉一大半真实字幕文件：
/// 日文字幕常见 Shift-JIS，中文字幕常见 GBK/GB18030，老资源还有 UTF-16。
/// 顺序很重要——先用 BOM 判定，再逐种尝试，最后才退回宽松解码。
public enum SubtitleTextDecoder {

    /// GB18030（兼容 GBK / GB2312）
    public static var gb18030: String.Encoding {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String.Encoding(rawValue: cf)
    }

    /// 尝试顺序：BOM → UTF-8 → Shift-JIS → GB18030 → EUC-JP → UTF-16 → Latin-1
    public static func decode(data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        // ① BOM 直接判定
        if let bomDecoded = decodeWithBOM(data) { return bomDecoded }

        // ② UTF-8 严格解码（绝大多数现代字幕）
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }

        // ③ 亚洲编码逐个尝试
        let candidates: [String.Encoding] = [
            .shiftJIS,
            gb18030,
            .japaneseEUC,
            .utf16LittleEndian,
            .utf16BigEndian
        ]
        for encoding in candidates {
            if let s = String(data: data, encoding: encoding), looksReasonable(s) {
                return s
            }
        }

        // ④ 兜底：不丢字节，宁可显示乱码也不返回 nil
        return String(data: data, encoding: .isoLatin1)
    }

    public static func decode(data: Data, path: String) -> String? {
        decode(data: data)
    }

    // MARK: - 内部

    private static func decodeWithBOM(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return nil
    }

    /// 粗略判断解码结果是否"像正常文本"：不能有大量替换字符或控制字符
    private static func looksReasonable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var bad = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if total > 4000 { break }
            if scalar == "\u{FFFD}" { bad += 1; continue }
            if scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t" {
                bad += 1
            }
        }
        guard total > 0 else { return false }
        return Double(bad) / Double(total) < 0.02
    }
}
