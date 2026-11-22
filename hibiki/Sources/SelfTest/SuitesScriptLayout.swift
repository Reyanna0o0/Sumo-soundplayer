import Foundation
import HibikiCore

func runScriptLayoutSuites(_ h: Harness) {
    // Test the decision rules independently of an OS model's changing scores.
    // Deliberately overconfident: shared-kanji exclusions must still hold.
    let evidence: BilingualText.Classifier = { text in
        text.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) } ? .japanese : .chinese
    }
    enum Appearance { case font, size, indent, identical }
    func row(_ text: String, index: Int, translation: Bool = false, appearance: Appearance = .font) -> ScriptTextLine {
        let layout = ScriptLineLayout(pageIndex: 0, left: appearance == .indent && translation ? 110 : 80,
            top: Double(index * 16 + 20), width: 300, height: 14, pageWidth: 600, pageHeight: 1200,
            fontName: appearance == .font ? (translation ? "ChineseFont" : "JapaneseFont") : "SameFont",
            fontSize: appearance == .size && translation ? 10 : 14, isReliable: true)
        return ScriptTextLine(text: text, layout: layout, sourceLineIndex: index,
            sourceRangeStart: index * 100, sourceRangeLength: text.utf16.count)
    }
    func block(_ index: Int, short: Bool = false, appearance: Appearance = .font, reverse: Bool = false,
               original: String? = nil, translation: String? = nil) -> ScriptLine {
        let boundaryCase = short && original == nil && translation == nil
        let jp = original ?? (boundaryCase ? "この説明を読んでください\n確認" : short ? "すみません" : "これは確かな台詞です")
        let zh = translation ?? (boundaryCase ? "请先阅读这段说明" : short ? "抱歉" : "这是一句完整的中文译文")
        var source = jp.components(separatedBy: "\n").enumerated().map {
            row($0.element, index: index * 3 + $0.offset, appearance: appearance)
        }
        source.append(row(zh, index: index * 3 + source.count, translation: true, appearance: appearance))
        if reverse, let translated = source.last { source = [translated] + source.dropLast() }
        let raw = source.map(\.text).joined(separator: "\n")
        return ScriptLine(index: index, text: short ? raw : jp, rawLine: raw,
            printedStartMS: index * 3000 + 1000, printedEndMS: index * 3000 + 2000,
            translatedText: short ? nil : zh, sourceLines: source)
    }
    func fixture(_ appearance: Appearance = .font, reverse: Bool = false) -> [ScriptLine] {
        (0..<5).map { block($0, short: $0 == 2, appearance: appearance, reverse: reverse) }
    }
    func separate(_ lines: [ScriptLine]) -> [ScriptLine] { ScriptLayoutBilingual.separating(lines, classifier: evidence) }

    h.suite("PDF 行来源与旧台本兼容") {
        h.test("纯文本入口不虚构版面，多片段 UTF16 来源可往返") {
            let text = ScriptDocument(text: "第一行\r\n二行目\r末尾\n")
            h.expectEqual(text.text, "第一行\n二行目\n末尾\n", "仅规范换行")
            h.expectEqual(text.lines.map(\.sourceLineIndex), [0, 1, 2, 3], "原行位置")
            h.expect(text.lines.allSatisfy { $0.layout == nil && $0.sourceRanges.isEmpty }, "不捏造 PDF 几何")
            var fragment = row("こんにちは😀—", index: 3)
            fragment.sourceRanges = [.init(start: 10, length: 7), .init(start: 80, length: 1)]
            let document = ScriptDocument(lines: [fragment])
            let data = try? JSONEncoder().encode(document)
            let restored = data.flatMap { try? JSONDecoder().decode(ScriptDocument.self, from: $0) }
            h.expectEqual(restored, document, "多段原页范围、字形和字体完整往返")
            h.expectNil(fragment.sourceRangeStart, "不冒充一个连续范围")
            let decorated = ScriptDocument(lines: [fragment], excludedLines: [row("7", index: 20)])
            let restoredDecoration = (try? JSONEncoder().encode(decorated)).flatMap { try? JSONDecoder().decode(ScriptDocument.self, from: $0) }
            h.expectEqual(restoredDecoration, decorated, "页边来源只留诊断")
            h.expectEqual(decorated.text, fragment.text, "页边装饰不进入正文")
        }
        h.test("章节匹配到导入保留准确正文来源，时间序号不混入") {
            let body = ["Track1", "1", "00:00:01,250 --> 00:00:02,300", "原文：こんにちは😀", "译文：你好呀😀",
                        "", "2", "00:00:03,100 --> 00:00:04,500", "原文：先生", "译文：老师"]
            let source = body.enumerated().map { row($0.element, index: $0.offset) }
            let track = TrackRecord(id: 10, workID: 1, fileName: "01.wav", filePath: "/w/01.wav", fileType: "wav")
            let matching = WorkScriptMatching(document: ScriptDocument(lines: source), fileName: "Track1.pdf", candidates: [track])
            let lines = matching.sections[0].lines
            h.expectEqual(lines.count, 2, "两个正文块")
            h.expectEqual(lines[0].sourceLines, Array(source[3...4]), "第一块原始两行含标签和 emoji")
            h.expectEqual(lines[1].sourceLines, Array(source[8...9]), "第二块准确范围")
            h.expectEqual(matching.suggestedAssignments[0].trackID, 10, "旧音轨匹配")
            let cues = ScriptImportPlan.cues(for: matching.sections[0], durationMS: 5000)
            h.expectEqual(cues.map(\.startMS), [1250, 3100], "准确起点")
            h.expectEqual(cues.map(\.endMS), [2300, 4500], "准确句尾")
            h.expectEqual(cues.map(\.status), [.ok, .ok], "时间状态")
            h.expectEqual(cues.map(\.translatedText), ["你好呀😀", "老师"], "旧明确双语不回退")
        }
        h.test("未打轴段落和连续标签保留来源，不借版面补时间") {
            let source = ["原文：先生", "译文：老师", "", "原文：甲：こんにちは", "译文：甲：你好呀", "原文：乙：またね", "译文：乙：再见呀"]
                .enumerated().map { row($0.element, index: $0.offset) }
            let section = ScriptSectioner.split(ScriptDocument(lines: source))[0]
            h.expectEqual(section.lines.map(\.translatedText), ["老师", "你好呀", "再见呀"], "旧标签分段")
            h.expectEqual(section.lines.map { $0.sourceLines.map(\.sourceLineIndex) }, [[0, 1], [3, 4], [5, 6]], "不把多对整段重复分给每句")
            h.expect(ScriptImportPlan.cues(for: section).allSatisfy { !$0.hasTiming && $0.status == .untimed }, "没有时间仍未打轴")
            let unknown = ScriptSectioner.split(ScriptDocument(lines: [row("すみません", index: 0), row("抱歉", index: 1)]))[0]
            h.expect(unknown.lines.allSatisfy { $0.translatedText == nil && $0.bilingualDecision?.method == .unresolved }, "无时间不追加局部猜配")
            h.expectEqual(unknown.lines.flatMap(\.sourceLines).map(\.text), ["すみません", "抱歉"], "无时间原文仍有来源")
        }
        h.test("旧单起点台本重排后来源仍对应原页位置") {
            let source = ["00:05 後の台詞です", "00:01 先の台詞です"].enumerated().map { row($0.element, index: $0.offset) }
            let section = ScriptSectioner.split(ScriptDocument(lines: source))[0]
            h.expectEqual(section.lines.map(\.printedStartMS), [1000, 5000], "保留旧排序")
            h.expectEqual(section.lines.map { $0.sourceLines.first?.sourceLineIndex }, [1, 0], "排序后不遗漏第一物理行")
        }
    }

    h.suite("局部版式仅辅助有语言证据的唯一边界") {
        h.test("字体字号缩进各自可提供角色区别，记录冻结锚点") {
            for (appearance, feature) in [(Appearance.font, ScriptBilingualDecision.Feature.fontName), (.size, .fontSize), (.indent, .indentation)] {
                let source = fixture(appearance)
                h.expectNil(BilingualText.split(source[2].rawLine, classifier: evidence), "共享汉字在语言层造成多个边界候选")
                let result = separate(source)
                h.expectEqual(result[2].text, "この説明を読んでください\n確認", "原文及同版式续行")
                h.expectEqual(result[2].translatedText, "请先阅读这段说明", "有强语言和可区别角色")
                h.expectEqual(result[2].bilingualDecision?.method, .localLayout, "解释方法")
                h.expectEqual(result[2].bilingualDecision?.features, [feature], "真实使用的版面依据")
                h.expectEqual(result[2].bilingualDecision?.anchorIndices, [0, 1, 3, 4], "只引用预先文本确认的邻块")
                h.expectEqual(result[2].sourceLines, source[2].sourceLines, "逐字和原页范围保持")
                h.expectEqual(result[2].printedStartMS, source[2].printedStartMS, "不改时间")
                h.expectEqual(result[2].printedEndMS, source[2].printedEndMS, "不猜句尾")
            }
            let reversed = separate(fixture(.font, reverse: true))
            h.expectEqual(reversed[2].translatedText, "请先阅读这段说明", "中文在前的局部格式也可识别")
            h.expectEqual(reversed[2].sourceLines.map(\.text), ["请先阅读这段说明", "この説明を読んでください", "確認"], "物理来源不重写")
        }
        h.test("同字体同缩进、仅上下排列或语言证据不足不配") {
            let identical = separate(fixture(.identical))[2]
            h.expectNil(identical.translatedText, "上下两行不够")
            h.expectEqual(identical.bilingualDecision?.reason, .indistinguishableRoles, "同样式拒配原因")
            let nilModel = ScriptLayoutBilingual.separating(fixture(), classifier: { _ in nil })[2]
            h.expectNil(nilModel.translatedText, "版面不能替代语言")
            h.expectEqual(nilModel.bilingualDecision?.reason, .uncertainLanguage, "语言证据缺失")
            var missing = fixture(); missing[2].sourceLines[1].layout = nil
            h.expectEqual(separate(missing)[2].bilingualDecision?.reason, .missingReliableLayout, "缺少版面不猜")
        }
        h.test("共享汉字续行和非语言标记即使模型高分也保留") {
            for word in ["了解", "先生", "大丈夫", "我慢", "我流", "我等", "完了", "終了", "一行目", "二行目", "目的", "無料", "確認", "禁止", "予約", "注意", "成功", "抱歉", "—", "123"] {
                var source = fixture(); source[2] = block(2, short: true, translation: word)
                let result = separate(source)[2]
                h.expectNil(result.translatedText, "不把日语续行 \(word) 强配")
                h.expectEqual(result.text, source[2].text, "拒配时正文原样")
            }
            var source = fixture(); source[2] = block(2, short: true, original: "先生", translation: "老师")
            h.expectNil(separate(source)[2].translatedText, "纯汉字原文不靠邻句补语言")
            source[2] = block(2, short: true, translation: "こんにちは是日语")
            h.expectNil(separate(source)[2].translatedText, "中文引用假名不强行分侧")
            source[2] = block(2, short: true, original: "甲：こんにちは", translation: "乙：抱歉")
            h.expectNil(separate(source)[2].translatedText, "不同角色保留")
            source = fixture()
            source[2].sourceLines = [row("これは結果です", index: 6), row("確認", index: 7, translation: true),
                row("予約", index: 8, translation: true), row("禁止", index: 9, translation: true)]
            source[2].text = source[2].sourceLines.map(\.text).joined(separator: "\n")
            h.expectNil(separate(source)[2].translatedText, "多个含糊短汉字不能凑够字数冒充明确中文块")
        }
        h.test("局部换向换样式是边界，不跨过去寻找多数证据") {
            var reverse = fixture(); reverse[3] = block(3, reverse: true)
            h.expectEqual(separate(reverse)[2].bilingualDecision?.reason, .conflictingPattern, "最近块换向即收束")
            var changed = fixture(); changed[3].sourceLines[1].layout?.fontName = "NewTranslationFont"
            h.expectNil(separate(changed)[2].translatedText, "局部字体改变不跨界")
            var orphan = fixture(); orphan[3].printedStartMS = nil; orphan[3].printedEndMS = nil
            h.expectNil(separate(orphan)[2].translatedText, "缺时间段切断邻域")
            var page = fixture(); for i in page[3].sourceLines.indices { page[3].sourceLines[i].layout?.pageIndex = 1 }
            h.expectNil(separate(page)[2].translatedText, "不跨页搜邻域")
            var lateConflict = fixture(); lateConflict.append(block(5, reverse: true))
            h.expectNil(separate(lateConflict)[2].translatedText, "已有足够锚点也不能忽视窗口中的换向")
            var uncertain = (0..<6).map { block($0, short: $0 == 2) }
            uncertain[3] = block(3, short: true, translation: "先生")
            h.expectNil(separate(uncertain)[2].translatedText, "不能跨过只有几何相似但语言未知的块")
        }
        h.test("错误时间、不可信版面与跨页块不能启用新推断") {
            var source = fixture(); source[2].printedEndMS = source[2].printedStartMS
            h.expectEqual(separate(source)[2].bilingualDecision?.reason, .incompleteTiming, "零长度区间")
            source = fixture(); source[2].printedStartMS = source[1].printedStartMS
            h.expectEqual(separate(source)[2].bilingualDecision?.reason, .incompleteTiming, "重复起点")
            source = fixture(); source[2].printedStartMS = 3000
            h.expectEqual(separate(source)[2].bilingualDecision?.reason, .incompleteTiming, "倒序起点")
            source = fixture(); source[2].sourceLines[0].layout?.isReliable = false
            h.expectEqual(separate(source)[2].bilingualDecision?.reason, .missingReliableLayout, "双栏等不可信标记")
            source = fixture(); source[2].sourceLines[0].layout?.left = .infinity
            h.expectEqual(separate(source)[2].bilingualDecision?.reason, .missingReliableLayout, "坏坐标")
            source = fixture(); source[2].sourceLines[1].layout?.pageIndex = 1
            h.expectEqual(separate(source)[2].bilingualDecision?.reason, .crossPage, "本轮不推断跨页短句")
        }
        h.test("推断不连锁、既有译文不改、缺原文不跨时间补配") {
            var source = (0..<6).map { block($0, short: [2, 4, 5].contains($0)) }
            let result = separate(source)
            h.expectEqual(result[2].bilingualDecision?.method, .localLayout, "当前块有三个独立锚点")
            h.expectNil(result[4].translatedText, "新推断不能成为下一处锚点")
            h.expectNil(result[5].translatedText, "末尾无两侧证据")
            source[2].translatedText = "手动译文"
            h.expectEqual(separate(source)[2].translatedText, "手动译文", "不改已有译文")
            source = fixture(); source[2].sourceLines = [row("抱歉", index: 5, translation: true)]; source[2].text = "抱歉"
            h.expectNil(separate(source)[2].translatedText, "缺一侧正文不能拿邻块填充")
        }
        h.test("多行块允许独特版面边界，不按物理行数对半分") {
            var source = fixture()
            source[2].sourceLines = [row("すみません", index: 4), row("少し待って", index: 5),
                                     row("请先阅读这段说明", index: 6, translation: true)]
            source[2].text = source[2].sourceLines.map(\.text).joined(separator: "\n")
            source[2].rawLine = source[2].text
            let result = separate(source)[2]
            h.expectEqual(result.text, "すみません\n少し待って", "两行原文")
            h.expectEqual(result.translatedText, "请先阅读这段说明", "一行译文")
            h.expectEqual((result.text + (result.translatedText ?? "")).filter { !$0.isWhitespace }.sorted(),
                          source[2].text.filter { !$0.isWhitespace }.sorted(), "不丢字不重复字")
        }
        h.test("独立舞台说明阻止无标签配对，明确标签仍优先") {
            let body = "少しここで待ってください。\n（书页翻动）\n请在这里稍等一下。"
            h.expectNil(BilingualText.split(body, classifier: evidence), "不把说明吞成译文")
            let section = ScriptSectioner.split("00:00:01,000 --> 00:00:02,000\n" + body)[0]
            h.expectEqual(section.lines[0].text, body, "时间块正文逐字保留")
            h.expectNil(section.lines[0].translatedText, "时间块不猜说明的角色")
            h.expectEqual(BilingualText.split("原文：（ドアを叩く）\n译文：（敲门）")?.translation, "（敲门）", "明确标签可以配对说明")
            var source = fixture()
            source[2].sourceLines = [row("少し待って", index: 4), row("（翻页）", index: 5, translation: true), row("抱歉", index: 6, translation: true)]
            source[2].text = source[2].sourceLines.map(\.text).joined(separator: "\n")
            h.expectNil(separate(source)[2].translatedText, "布局规则同样不得吞说明")
        }
        h.test("不可靠 PDF 退回原文，不能经旧文字入口再次自动混配") {
            let body = ["図書館で本を探しています。", "我在图书馆找书。"]
            var source = body.enumerated().map { row($0.element, index: $0.offset) }
            for index in source.indices { source[index].layout?.isReliable = false }
            let noTime = ScriptSectioner.split(ScriptDocument(lines: source))[0]
            h.expect(noTime.lines.allSatisfy { $0.translatedText == nil }, "无时间不可靠 PDF 不拆")
            h.expectEqual(noTime.lines.count, 2, "保留旧逐行行为，不整页合为一条")
            h.expectEqual(noTime.lines.flatMap(\.sourceLines), source, "原顺序来源保留")
            let timed = ScriptSectioner.split(ScriptDocument(lines: [row("00:00:01,000 --> 00:00:02,000", index: 4)] + source))[0]
            h.expectNil(timed.lines[0].translatedText, "完整时间也不能证明不可靠正文顺序")
            h.expectEqual(timed.lines[0].text, body.joined(separator: "\n"), "原文不丢")
            source[0].text = "原文：先生"; source[1].text = "译文：老师"
            let labelled = ScriptSectioner.split(ScriptDocument(lines: source))[0]
            h.expectEqual(labelled.lines[0].translatedText, "老师", "明确语言标签仍可识别")
            let plain = ScriptSectioner.split(body.joined(separator: "\n"))[0]
            h.expectEqual(plain.lines[0].translatedText, "我在图书馆找书。", "TXT 无 PDF 元数据继续旧规则")
        }
        h.test("PDF 重复带引号正文即使无法回指来源也不能退回自动配对") {
            let text = "「こちらへどうぞ。 | 请往这边走。」"
            var source = [row(text, index: 0), row(text, index: 1)]
            for index in source.indices { source[index].layout?.isReliable = false }
            let section = ScriptSectioner.split(ScriptDocument(lines: source))[0]
            h.expectEqual(section.lines.count, 2, "保留旧逐行数量")
            h.expect(section.lines.allSatisfy { $0.translatedText == nil }, "来源匹配失败不是纯文本许可证")
            h.expect(section.lines.allSatisfy { $0.text == "こちらへどうぞ。 | 请往这边走。" }, "未配正文仍完整")
            let plain = ScriptSectioner.split(text + "\n" + text)[0]
            h.expect(plain.lines.allSatisfy { $0.translatedText == "请往这边走。" }, "原 String 入口继续支持同排分栏")
        }
    }
}
