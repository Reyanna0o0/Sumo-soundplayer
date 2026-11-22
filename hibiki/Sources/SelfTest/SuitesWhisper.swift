import Foundation
import HibikiCore

/// whisper JSON 解析
func runWhisperSuites(_ h: Harness) {

    h.suite("whisper JSON 解析") {
        h.test("解析词级时间") {
            let json = """
            {
              "transcription": [
                {
                  "offsets": {"from": 0, "to": 2200},
                  "text": " ねえ聞こえてる",
                  "tokens": [
                    {"text": " ねえ", "offsets": {"from": 0, "to": 800}},
                    {"text": " 聞こえてる", "offsets": {"from": 800, "to": 2200}}
                  ]
                }
              ]
            }
            """
            let tokens = WhisperJSONParser.parseTokens(Data(json.utf8))
            h.expectEqual(tokens.count, 2, "两个词")
            h.expectEqual(tokens[0].text, "ねえ", "第一个词（空格已去掉）")
            h.expectEqual(tokens[0].startMS, 0, "起始")
            h.expectEqual(tokens[1].endMS, 2200, "结束")
        }

        h.test("没有词级时退回整段") {
            let json = """
            {"transcription": [{"offsets": {"from": 1000, "to": 3000}, "text": " こんにちは"}]}
            """
            let tokens = WhisperJSONParser.parseTokens(Data(json.utf8))
            h.expectEqual(tokens.count, 1, "一段")
            h.expectEqual(tokens[0].text, "こんにちは", "文本")
            h.expectEqual(tokens[0].startMS, 1000, "起始")
        }

        h.test("去掉特殊标记") {
            let json = """
            {"transcription": [{"offsets": {"from": 0, "to": 500},
              "tokens": [{"text": "[_BEG_] <|ja|>こんにちは", "offsets": {"from": 0, "to": 500}}]}]}
            """
            let tokens = WhisperJSONParser.parseTokens(Data(json.utf8))
            h.expectEqual(tokens.first?.text, "こんにちは", "标记被清理")
        }

        h.test("空标记的词被跳过") {
            let json = """
            {"transcription": [{"offsets": {"from": 0, "to": 900},
              "tokens": [
                {"text": "[_BEG_]", "offsets": {"from": 0, "to": 100}},
                {"text": "はい", "offsets": {"from": 100, "to": 900}}
              ]}]}
            """
            let tokens = WhisperJSONParser.parseTokens(Data(json.utf8))
            h.expectEqual(tokens.count, 1, "只剩一个")
            h.expectEqual(tokens[0].text, "はい", "内容")
        }

        h.test("去掉 [_TT_276] 这种时间标记") {
            let json = """
            {"transcription": [{"offsets": {"from": 0, "to": 900},
              "tokens": [{"text": "はい。[_TT_276]", "offsets": {"from": 0, "to": 900}}]}]}
            """
            let tokens = WhisperJSONParser.parseTokens(Data(json.utf8))
            h.expectEqual(tokens.first?.text, "はい。", "标记去掉、句号保留")
        }

        h.test("坏 JSON 不崩") {
            h.expectEqual(WhisperJSONParser.parseTokens(Data("不是json".utf8)).count, 0, "返回空")
            h.expectEqual(WhisperJSONParser.parseTokens(Data("{}".utf8)).count, 0, "缺字段返回空")
        }

        h.test("解析结果能直接拼字幕") {
            let json = """
            {"transcription": [{"offsets": {"from": 0, "to": 3000},
              "tokens": [
                {"text": "あ、", "offsets": {"from": 1000, "to": 1400}},
                {"text": "そこは", "offsets": {"from": 1400, "to": 2000}},
                {"text": "だめ", "offsets": {"from": 2000, "to": 2600}}
              ]}]}
            """
            let tokens = WhisperJSONParser.parseTokens(Data(json.utf8))
            let cues = TokenCueBuilder.build(tokens: tokens)
            h.expectEqual(cues.count, 1, "一句")
            h.expectEqual(cues[0].text, "あ、そこはだめ", "拼起来")
        }
    }
}
