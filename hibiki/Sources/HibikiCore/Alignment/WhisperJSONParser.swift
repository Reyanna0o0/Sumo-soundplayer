import Foundation

/// 解析 whisper.cpp 输出的 JSON，取"词级时间"。
///
/// whisper.cpp `-ojf` 生成的格式大致是：
/// ```json
/// { "transcription": [ { "offsets": {"from": 0, "to": 1200},
///                        "text": " こんにちは",
///                        "tokens": [ {"text": "こん", "offsets": {"from": 0, "to": 400}}, … ] } ] }
/// ```
/// `offsets` 单位是毫秒。
public enum WhisperJSONParser {

    public static func parseTokens(_ data: Data) -> [TimedToken] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = root["transcription"] as? [[String: Any]] else {
            return []
        }

        var tokens: [TimedToken] = []
        for segment in segments {
            // 优先用词级 token
            if let segmentTokens = segment["tokens"] as? [[String: Any]], !segmentTokens.isEmpty {
                for token in segmentTokens {
                    guard let text = token["text"] as? String,
                          let offsets = token["offsets"] as? [String: Any],
                          let from = offsets["from"] as? Int,
                          let to = offsets["to"] as? Int else { continue }
                    let cleaned = clean(text)
                    guard !cleaned.isEmpty else { continue }
                    tokens.append(TimedToken(text: cleaned, startMS: from, endMS: max(from + 1, to)))
                }
                continue
            }

            // 退回整段
            guard let text = segment["text"] as? String,
                  let offsets = segment["offsets"] as? [String: Any],
                  let from = offsets["from"] as? Int,
                  let to = offsets["to"] as? Int else { continue }
            let cleaned = clean(text)
            guard !cleaned.isEmpty else { continue }
            tokens.append(TimedToken(text: cleaned, startMS: from, endMS: max(from + 1, to)))
        }
        return tokens
    }

    /// whisper 的 token 常带前导空格和特殊标记（`[_BEG_]`、`<|ja|>`）
    static func clean(_ text: String) -> String {
        var result = text
        // whisper 的特殊标记有两种写法：
        //   [_BEG_]  [_TT_276]  ← 方括号包住、下划线分隔
        //   <|ja|>   <|startoftranscript|>
        let patterns = [
            "\\[_+[A-Za-z0-9_]*(?:\\s+\\d+)?\\]",
            "<\\|[^|]*\\|>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
