import Foundation
import HibikiCore

/// 导出与台本对齐的测试套件
func runExportAlignSuites(_ h: Harness) {

    func cues(_ specs: [(Int, Int, String)]) -> [SubtitleCue] {
        specs.enumerated().map { SubtitleCue(index: $0.offset, startMS: $0.element.0, endMS: $0.element.1, text: $0.element.2) }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("字幕导出") {
        let sample = cues([(1000, 3500, "あ、そこはだめ"), (4000, 6000, "そんなこと")])

        h.test("SRT 结构") {
            let out = SubtitleExporter.export(sample, format: .srt)
            h.expect(out.contains("1\n00:00:01,000 --> 00:00:03,500\nあ、そこはだめ"), "第一条")
            h.expect(out.contains("2\n00:00:04,000 --> 00:00:06,000\nそんなこと"), "第二条")
            h.expect(out.hasSuffix("\n\n"), "以空行结尾")
        }

        h.test("SRT 往返一致") {
            let out = SubtitleExporter.export(sample, format: .srt)
            let parsed = SRTSubtitleParser.parse(out)
            h.expectEqual(parsed.cues.count, 2, "条数")
            h.expectEqual(parsed.cues[0].startMS, 1000, "start")
            h.expectEqual(parsed.cues[0].endMS, 3500, "end")
            h.expectEqual(parsed.cues[1].text, "そんなこと", "text")
        }

        h.test("VTT 带头部") {
            let out = SubtitleExporter.export(sample, format: .vtt)
            h.expect(out.hasPrefix("WEBVTT\n\n"), "头部")
            h.expect(out.contains("00:00:01.000 --> 00:00:03.500"), "时间用点")
        }

        h.test("VTT 往返一致") {
            let out = SubtitleExporter.export(sample, format: .vtt)
            let parsed = WebVTTSubtitleParser.parse(out)
            h.expectEqual(parsed.cues.count, 2, "条数")
            h.expectEqual(parsed.cues[0].startMS, 1000, "start")
        }

        h.test("LRC 结构") {
            let out = SubtitleExporter.export(sample, format: .lrc)
            h.expect(out.contains("[00:01.00]あ、そこはだめ"), "第一条")
            h.expect(out.contains("[00:04.00]そんなこと"), "第二条")
        }

        h.test("ASS 结构") {
            let out = SubtitleExporter.export(sample, format: .ass)
            h.expect(out.contains("[Script Info]"), "Script Info")
            h.expect(out.contains("[V4+ Styles]"), "Styles")
            h.expect(out.contains("[Events]"), "Events")
            h.expect(out.contains("Format: Layer, Start, End"), "Format 行")
            h.expect(out.contains("Dialogue: 0,0:00:01.00,0:00:03.50,Default,"), "Dialogue 行")
        }

        h.test("ASS 往返一致") {
            let out = SubtitleExporter.export(sample, format: .ass)
            let parsed = ASSSubtitleParser.parse(out)
            h.expectEqual(parsed.cues.count, 2, "条数")
            h.expectEqual(parsed.cues[0].startMS, 1000, "start")
            h.expectEqual(parsed.cues[0].text, "あ、そこはだめ", "text")
        }

        h.test("双语同一文件（两行）") {
            var withT = sample
            withT[0].translatedText = "Ah, not there"
            let out = SubtitleExporter.export(withT, format: .srt, options: .init(bilingualLayout: .twoLines))
            h.expect(out.contains("あ、そこはだめ\nAh, not there"), "原文与译文相邻")
        }

        h.test("双语拆成两个文件") {
            var withT = sample
            withT[0].translatedText = "Ah, not there"
            withT[1].translatedText = "Such a thing"
            let files = SubtitleExporter.exportFiles(
                withT, format: .srt, baseName: "作品名",
                primaryLanguage: "ja", secondaryLanguage: "zh",
                options: .init(bilingualLayout: .splitFiles)
            )
            h.expectEqual(files.count, 2, "两个文件")
            h.expectEqual(files[0].suggestedFileName, "作品名.ja.srt", "原文文件名")
            h.expectEqual(files[1].suggestedFileName, "作品名.zh.srt", "译文文件名")
            h.expect(files[0].content.contains("あ、そこはだめ"), "原文内容")
            h.expect(files[1].content.contains("Ah, not there"), "译文内容")
            h.expect(!files[1].content.contains("あ、そこはだめ"), "译文文件不含日文原文")
        }

        h.test("没有译文时只出一个文件") {
            let files = SubtitleExporter.exportFiles(
                sample, format: .srt, baseName: "x",
                primaryLanguage: "ja", secondaryLanguage: "zh",
                options: .init(bilingualLayout: .splitFiles)
            )
            h.expectEqual(files.count, 1, "一个文件")
        }

        h.test("文件名非法字符被清理") {
            let name = SubtitleExporter.suggestedFileName(
                baseName: "作品/名:测试", language: nil, format: .srt
            )
            h.expectEqual(name, "作品_名_测试.srt", "清理结果")
        }

        h.test("只导出待校对条目") {
            var mixed = sample
            mixed[1].status = .unaligned
            let out = SubtitleExporter.exportNeedsReview(mixed, format: .srt)
            h.expect(out.contains("そんなこと"), "含未对齐条目")
            h.expect(!out.contains("あ、そこはだめ"), "不含已确认条目")
        }

        h.test("CSV 转义") {
            var tricky = cues([(0, 1000, "含,逗号")])
            tricky[0].translatedText = "含\"引号\""
            let csv = SubtitleExporter.exportCSV(tricky)
            h.expect(csv.contains("\"含,逗号\""), "逗号需要引号包裹")
            h.expect(csv.contains("\"\"引号\"\""), "引号需要双写")
            h.expect(csv.hasPrefix("序号,开始,结束"), "表头")
        }

        h.test("按时间排序导出") {
            let unsorted = cues([(5000, 6000, "后"), (1000, 2000, "前")])
            let out = SubtitleExporter.export(unsorted, format: .srt)
            let idxFront = out.range(of: "前")?.lowerBound
            let idxBack = out.range(of: "后")?.lowerBound
            h.expectNotNil(idxFront, "前")
            h.expectNotNil(idxBack, "后")
            if let a = idxFront, let b = idxBack {
                h.expect(a < b, "「前」应排在「后」之前")
            }
        }
        h.test("一毫秒字幕可作为有效区间从三种格式读回") {
            let line = SubtitleCue(index: 0, startMS: 61_998, endMS: 61_999, text: "短句", status: .provisional)
            for format in [SubtitleFormat.srt, .vtt, .ass] {
                let file = SubtitleExporter.export([line], format: format)
                let first = SubtitleParser.parse(file, formatHint: format).cues.first
                h.expect(first?.hasTiming == true, "\(format) 时间没有合并成零长度")
                h.expectEqual(first?.startMS, format == .ass ? 61_990 : 61_998, "\(format) 起点")
                h.expectEqual(first?.endMS, format == .ass ? 62_000 : 61_999, "\(format) 终点")
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("台本文本归一化") {
        h.test("全角转半角并小写") {
            h.expectEqual(ScriptNormalizer.normalize("ＡＢＣ１２３"), "abc123", "全角字母数字")
        }
        h.test("去掉标点与空白") {
            h.expectEqual(ScriptNormalizer.normalize("あ、そこは だめ！"), "あそこはだめ", "标点空白")
        }
        h.test("保留假名与汉字") {
            h.expectEqual(ScriptNormalizer.normalize("ひらがなカタカナ漢字"), "ひらがなカタカナ漢字", "保留")
        }
        h.test("括号注释被整体去掉") {
            h.expectEqual(ScriptNormalizer.normalize("（ドアを叩く）こんにちは"), "こんにちは", "注释")
        }
        h.test("空行得到空字符") {
            h.expect(ScriptNormalizer.normalizedCharacters("　、。！").isEmpty, "全是标点")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("台本锚点对齐") {
        // 构造一段"识别结果"：第一句 0~1000ms，第二句 2000~2700ms
        let tokens: [TimedToken] = [
            TimedToken(text: "あ", startMS: 0, endMS: 200),
            TimedToken(text: "そこ", startMS: 200, endMS: 500),
            TimedToken(text: "は", startMS: 500, endMS: 600),
            TimedToken(text: "だめ", startMS: 600, endMS: 900),
            TimedToken(text: "よ", startMS: 900, endMS: 1000),
            TimedToken(text: "そんな", startMS: 2000, endMS: 2400),
            TimedToken(text: "こと", startMS: 2400, endMS: 2700)
        ]

        h.test("两行都能对上") {
            let lines = ["あ、そこはだめよ", "そんなこと"]
            let result = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            h.expectEqual(result.count, 2, "行数")
            h.expectEqual(result[0].status, .ok, "第一行高置信")
            h.expectEqual(result[0].startMS, 0, "第一行开始")
            h.expectEqual(result[0].endMS, 1000, "第一行结束")
            h.expectEqual(result[1].startMS, 2000, "第二行开始")
            h.expectEqual(result[1].endMS, 2700, "第二行结束")
        }

        h.test("匹配率超过阈值") {
            let result = ScriptAligner.align(scriptLines: ["あ、そこはだめよ"], tokens: tokens)
            h.expect(result[0].matchRatio >= 0.8, "完全匹配率应较高，实际 \(result[0].matchRatio)")
        }

        h.test("台本里有但音频里没有的行判为未对齐") {
            let lines = ["あ、そこはだめよ", "まったく違う文章です"]
            var result = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            // 允许第二行因为按比例估位置而拿到时间，但必须是 unaligned
            h.expectEqual(result[1].status, .unaligned, "第二行应判未对齐")
            h.expect(result[1].matchRatio < 0.45, "匹配率应低")
            if result.count > 1 { result[1].startMS = nil }  // 消除未使用警告
        }

        h.test("空行不对齐") {
            let lines = ["あ、そこはだめよ", "", "そんなこと"]
            let result = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            h.expectEqual(result[1].status, .unaligned, "空行未对齐")
            h.expectEqual(result[1].startMS, nil, "空行无时间")
            h.expectEqual(result[2].startMS, 2000, "第三行仍能对齐")
        }

        h.test("纯注释行不对齐") {
            let lines = ["あ、そこはだめよ", "（ドアを叩く）", "そんなこと"]
            let result = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            h.expectEqual(result[1].status, .unaligned, "纯注释未对齐")
        }

        h.test("时间单调不倒流") {
            let lines = ["そんなこと", "あ、そこはだめよ"]  // 故意写反顺序
            let result = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            for i in 1..<result.count {
                if let prev = result[i - 1].endMS, let curr = result[i].startMS {
                    h.expect(curr >= prev, "第 \(i) 行开始 \(curr) 不应早于上一行结束 \(prev)")
                }
            }
        }

        h.test("空识别结果全部未对齐") {
            let result = ScriptAligner.align(scriptLines: ["あ", "い"], tokens: [])
            h.expectEqual(result.count, 2, "行数")
            h.expect(result.allSatisfy { $0.status == .unaligned }, "全部未对齐")
            h.expect(result.allSatisfy { $0.startMS == nil }, "全部无时间")
        }

        h.test("转成字幕条目") {
            let lines = ["あ、そこはだめよ", "そんなこと"]
            let aligned = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            let cues = ScriptAligner.makeCues(from: aligned)
            h.expectEqual(cues.count, 2, "条数")
            h.expectEqual(cues[0].startMS, 0, "start")
            h.expectEqual(cues[1].text, "そんなこと", "text")
        }

        h.test("转字幕时可附带译文") {
            let lines = ["あ、そこはだめよ"]
            let aligned = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            let cues = ScriptAligner.makeCues(from: aligned, translated: ["Ah, not there"])
            h.expectEqual(cues[0].translatedText, "Ah, not there", "译文")
        }

        h.test("可丢弃未对齐行") {
            let lines = ["あ、そこはだめよ", "まったく違う文章です"]
            let aligned = ScriptAligner.align(scriptLines: lines, tokens: tokens)
            let cues = ScriptAligner.makeCues(from: aligned, dropUnalignable: true)
            h.expectEqual(cues.count, 1, "只剩 1 条")
        }

        h.test("识别结果有错字时仍能对齐") {
            // 识别把「だめ」听成「だべ」
            let noisy: [TimedToken] = [
                TimedToken(text: "あ", startMS: 0, endMS: 200),
                TimedToken(text: "そこ", startMS: 200, endMS: 500),
                TimedToken(text: "は", startMS: 500, endMS: 600),
                TimedToken(text: "だべ", startMS: 600, endMS: 900),
                TimedToken(text: "よ", startMS: 900, endMS: 1000)
            ]
            let result = ScriptAligner.align(scriptLines: ["あ、そこはだめよ"], tokens: noisy)
            h.expectEqual(result[0].status, .ok, "一个错字不该判失败")
            h.expectEqual(result[0].startMS, 0, "start")
        }
    }
}
