import Foundation
import HibikiCore

func runBilingualSuites(_ h: Harness) {
    // Deliberately overconfident test evidence: the boundary rules must still
    // reject shared-kanji short words, changing speakers, and alternating blocks.
    let evidence: BilingualText.Classifier = { text in
        text.unicodeScalars.contains { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) } ? .japanese : .chinese
    }
    func split(_ text: String) -> BilingualText.Pair? { BilingualText.split(text, classifier: evidence) }

    h.suite("双语语言块边界") {
        h.test("明确标签无需平台模型，短汉字与不同原文语言均可保留") {
            let pairs = ["原文：先生\n译文：老师", "译文：老师\n原文：先生", "原文：Hello\n译文：你好"]
            for (i, text) in pairs.enumerated() {
                let pair = BilingualText.split(text, classifier: { _ in nil })
                h.expectEqual(pair?.original, i == 2 ? "Hello" : "先生", "原文标签")
                h.expectEqual(pair?.translation, i == 2 ? "你好" : "老师", "译文标签")
            }
            h.expectEqual(split("JA: 先生 ZH: 老师")?.translation, "老师", "同一行的显式标签")
        }
        h.test("两行原文与三行译文按语言块对应，不按奇偶行") {
            let original = "これは長い台詞です。\nまだ続いています。"
            let translation = "这是一句比较长的台词。\n因为排版的关系，\n译者把它分成了三行。"
            for text in [original + "\n" + translation, translation + "\n" + original] {
                let pair = split(text)
                h.expectEqual(pair?.original, original, "完整原文块")
                h.expectEqual(pair?.translation, translation, "完整译文块")
                let kept = (pair?.original ?? "") + (pair?.translation ?? "")
                h.expectEqual(kept.filter { !$0.isWhitespace }.sorted(), text.filter { !$0.isWhitespace }.sorted(), "非空白字符无丢失")
            }
        }
        h.test("短中文需要积极证据，共用汉字不靠模型高分强判") {
            for chinese in ["太好了", "你好吗", "听见了", "你们", "謝謝你"] {
                h.expectEqual(split("よかった\n" + chinese)?.translation, chinese, "可辨认的短中文 \(chinese)")
            }
            for ambiguous in ["先生", "了解", "大丈夫", "一行目", "二行目", "目的", "完了", "終了", "我流", "我慢", "我等"] {
                h.expectNil(split("こんにちは\n" + ambiguous), "共用汉字 \(ambiguous)")
            }
            h.expectEqual(split("本気で\n我是认真的")?.translation, "我是认真的", "模型与真假名字母一致时不要求假名占多数")
        }
        h.test("边界短句含糊、多组交替、缺译与同语言正文均保留") {
            for text in ["こんにちは\n先生\n这是一句完整的译文。",
                         "こんにちは\n你听得见吗\n聞こえるよ\n当然听得见了",
                         "こんにちは\nまだ続いているよ", "这是中文一行\n这是中文第二行", "こんばんは"] {
                h.expectNil(split(text), "不猜分界 \(text)")
            }
        }
        h.test("明确分栏可拆，无边界的混写不按字符切断") {
            for separator in ["\t", " | ", " ｜ ", " / "] {
                h.expectEqual(split("こんにちは" + separator + "你好呀")?.translation, "你好呀", "分栏 \(separator)")
            }
            h.expectNil(split("こんにちは你好呀"), "没有排版分界")
            h.expectNil(split("今日は A / B を選ぶ\nこれは説明です"), "同语言斜杠不是双语")
        }
        h.test("角色不相同则不配对，中文引用日语词也不是日文块") {
            h.expectNil(split("甲：こんにちは\n乙：你今天好吗"), "角色不同")
            let mixed = BilingualText.split("日语里说こんにちは\n这只是中文的补充说明。", classifier: { _ in .chinese })
            h.expectNil(mixed, "不能仅见假名就认为日文")
            h.expectNil(split("中文名字・中文名字\n中文台词ー中文台词"), "中点与长音符不是假名")
        }
        h.test("无平台模型保守回退，已有人工译文与字幕身份时间保持") {
            h.expectNil(BilingualText.split("こんにちは\n你好呀", classifier: { _ in nil }), "无语言依据不猜")
            let cue = SubtitleCue(index: 7, startMS: 1234, endMS: 9876, text: "原文：先生\n译文：老师", status: .provisional)
            let separated = BilingualText.separating([cue])[0]
            h.expectEqual(separated.id, cue.id, "ID")
            h.expectEqual(separated.index, cue.index, "下标")
            h.expectEqual(separated.startMS, cue.startMS, "起点")
            h.expectEqual(separated.endMS, cue.endMS, "句尾")
            h.expectEqual(separated.status, cue.status, "状态")
            var edited = cue
            edited.translatedText = "人工译文"
            h.expectEqual(BilingualText.separating([edited]), [edited], "不覆盖人工译文")
        }
    }

    h.suite("台本完整时间与双语导入") {
        h.test("PDF 中完整 SRT 时间块保存真实句尾，首块前正文保持无时间") {
            let text = "Track1\n前言文字\n1\n00:00:01,250 --> 00:00:06,920\n原文：こんにちは\n译文：你好呀\n\n2\n00:00:08,100 --> 00:00:09,300\n原文：先生\n译文：老师"
            let section = ScriptSectioner.split(text)[0]
            let cues = ScriptImportPlan.cues(for: section)
            h.expectEqual(cues.count, 3, "前言与两个完整块")
            h.expectEqual(cues[0].status, .untimed, "前言不猜时间归属")
            h.expectEqual(cues[1].text, "こんにちは", "不残留箭头")
            h.expectEqual(cues[1].translatedText, "你好呀", "译文字段")
            h.expectEqual(cues[1].startMS, 1250, "印刷起点")
            h.expectEqual(cues[1].endMS, 6920, "不是五秒估算或下一句起点")
            h.expectEqual(cues[1].status, .ok, "完整区间")
            h.expectEqual(cues[2].text, "先生", "第二块不移位")
        }
        h.test("短句不配不会推移下一块，空时间块不制造可播放空句") {
            let text = "Track1\n00:00:01,000 --> 00:00:02,000\nこんにちは\n先生\n00:00:03,000 --> 00:00:04,000\n00:00:05,000 --> 00:00:06,000\n原文：まだいるよ\n译文：我还在这里。"
            let cues = ScriptImportPlan.cues(for: ScriptSectioner.split(text)[0])
            h.expectEqual(cues.count, 2, "只保存有正文的两个块")
            h.expectEqual(cues[0].text, "こんにちは\n先生", "不确定处原样保留")
            h.expectNil(cues[0].translatedText, "不强猜先生")
            h.expectEqual(cues[1].translatedText, "我还在这里。", "后块独立")
            h.expectEqual(cues[1].startMS, 5000, "后块时间正确")
        }
        h.test("空段或明确序号后缺少时间的文字独立保留") {
            let text = "1\n00:00:01,000 --> 00:00:02,000\n原文：あのね\n译文：你听我说\n\n缺少时间的一句\n\n2\n00:00:03,000 --> 00:00:04,000\n原文：ここだよ\n译文：就在这里\n\n3\n缺少时间的另一句\n4\n00:00:05,000 --> 00:00:06,000\n原文：最後だよ\n译文：这是最后一句"
            let cues = ScriptImportPlan.cues(for: ScriptSectioner.split(text)[0])
            h.expectEqual(cues.map(\.status), [.ok, .untimed, .ok, .untimed, .ok], "不沿用上一块时间")
            h.expectEqual(cues[0].translatedText, "你听我说", "前块译文不混入缺时正文")
            h.expectEqual(cues[1].text, "缺少时间的一句", "空段后原文保留")
            h.expectEqual(cues[3].text, "缺少时间的另一句", "序号后原文保留")
            let numbers = ScriptSectioner.split("00:00:01,000 --> 00:00:02,000\n番号は\n123")[0]
            h.expectEqual(numbers.lines[0].text, "番号は\n123", "最后一句中的数字不被当序号删除")
            let nextNumbers = ScriptSectioner.split("00:00:01,000 --> 00:00:02,000\n番号は\n42\n00:00:03,000 --> 00:00:04,000\n次です")[0]
            h.expectEqual(nextNumbers.lines[0].text, "番号は\n42", "没有序号体系不因下一时间行删除数字对白")
            let numberedBody = ScriptSectioner.split("1\n00:00:01,000 --> 00:00:02,000\n番号は\n2\nですよ\n2\n00:00:03,000 --> 00:00:04,000\n次です")[0]
            h.expectEqual(numberedBody.lines[0].text, "番号は\n2\nですよ", "即使有序号体系也不能把正文数字硬当缺时编号")
        }
        h.test("倒置或越过音频末尾的完整区间不伪造句尾") {
            let section = ScriptSectioner.split("Track1\n00:00:05,000 --> 00:00:04,000\n原文：あのね\n译文：你听我说\n00:00:08,000 --> 00:00:12,000\n原文：ここだよ\n译文：就在这里")[0]
            let cues = ScriptImportPlan.cues(for: section, durationMS: 10000)
            h.expect(cues.allSatisfy { $0.status == .untimed && !$0.hasTiming }, "非法完整范围只供查阅")
            h.expect(cues[0].text.hasPrefix("[00:05.000 --> 00:04.000]"), "原范围保留")
            h.expectEqual(cues[1].translatedText, "就在这里", "时间无效也保留译文")
        }
        h.test("普通台本的换行和章节不被双语规则挪动") {
            let plain = ScriptParser.parse("甲：第一句\n甲：第二句")
            h.expectEqual(plain.map(\.text), ["第一句", "第二句"], "原来逐行规则")
            let wrapped = ScriptSectioner.split("Track1\n0:01 これは折り返しのある\n日本語の台詞です。\n0:04 次の台詞です。")[0]
            h.expectEqual(wrapped.lines[0].text, "これは折り返しのある\n日本語の台詞です。", "单起点日文折行")
            h.expectEqual(ScriptImportPlan.cues(for: wrapped)[0].status, .provisional, "单起点仍待校准")
            let chapters = ScriptSectioner.split("Track1\nこんにちは\nTrack2\n你好呀")
            h.expect(chapters.allSatisfy { $0.lines.allSatisfy { $0.translatedText == nil } }, "不跨章节配对")
            h.expectEqual(ScriptParser.parse("原文：Hello\n译文：你好").first?.translatedText, "你好", "无时间明确双语")
            let parenthesis = ScriptParser.parse("原文：今日は（いい天気）ですね\n译文：今天天气很好啊")[0]
            h.expectEqual(parenthesis.text, "今日は（いい天気）ですね", "正文括号前的日语不删作角色")
            h.expectNil(parenthesis.speaker, "没有明确角色前缀")
            let quoted = ScriptSectioner.split("00:00:01,000 --> 00:00:02,000\n原文：今日は「いい天気」\n译文：今天“天气很好”")[0]
            h.expectEqual(quoted.lines[0].text, "今日は「いい天気」", "正文引号逐字保留")
            h.expectEqual(quoted.lines[0].translatedText, "今天“天气很好”", "译文引号逐字保留")
            let labels = ScriptParser.parse("原文：第一句です\n还有日文续行\n译文：这是第一句\n原文：次です\n译文：这是第二句\n译文的折行")
            h.expectEqual(labels.count, 2, "连续显式标签按角色转换分成两对")
            h.expectEqual(labels[1].translatedText, "这是第二句\n译文的折行", "第二对完整译文")
        }
        h.test("人为合并章节保留完整时间参考并解除时间绑定") {
            let mapping = OrderedScriptMapping(sections: ScriptSectioner.split("TR1\n00:00:01,000 --> 00:00:03,000\n原文：あのね\n译文：你听我说\nTR2\n00:00:02,000 --> 00:00:04,000\n次です"))
            let section = mapping.assignments(trackIDs: [7], starts: [:])![0].section
            h.expect(section.lines.allSatisfy { $0.printedStartMS == nil && $0.printedEndMS == nil }, "清除两端")
            h.expect(section.lines[0].text.hasPrefix("[00:01.000 --> 00:03.000]"), "供手工校准的完整参考")
            h.expectEqual(section.lines[0].translatedText, "你听我说", "译文保留")
        }
        h.test("字幕统一入口拆双语，不改原格式的区间") {
            let source = "1\n00:00:01,250 --> 00:00:06,920\n原文：先生\n译文：老师\n"
            let cue = SubtitleParser.parse(source, formatHint: .srt).cues[0]
            h.expectEqual(cue.text, "先生", "原文")
            h.expectEqual(cue.translatedText, "老师", "译文")
            h.expectEqual(cue.startMS, 1250, "SRT 起点")
            h.expectEqual(cue.endMS, 6920, "SRT 句尾")
            for (source, format) in [("1\n00:00:01,000 --> 00:00:02,000\n原文：先生<br/>译文：老师", SubtitleFormat.srt),
                                      ("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n原文：先生<BR>译文：老师", .vtt)] {
                let parsed = SubtitleParser.parse(source, formatHint: format).cues[0]
                h.expectEqual(parsed.text, "先生", "HTML换行保留为分界")
                h.expectEqual(parsed.translatedText, "老师", "HTML换行后的译文")
                h.expectEqual(parsed.endMS, 2000, "不改变格式时间")
            }
        }
        h.test("时间行左右混有正文时不丢字、不伪造已识别区间") {
            for text in ["00:00:01,000 --> 00:00:02,000 原文：こんにちは\n译文：你好呀",
                         "00:00:01,000 备注 --> 00:00:02,000\n正文"] {
                let cues = ScriptImportPlan.cues(for: ScriptSectioner.split(text)[0])
                h.expectEqual(cues.first?.text, text, "不丢行尾settings或左侧剩余文字")
                h.expect(cues.allSatisfy { !$0.hasTiming }, "不支持的混排保留无时间原文")
            }
        }
    }

    h.suite("双语台本数据库往返与旧稿保护") {
        func setup() throws -> (SubtitleRepository, TrackRecord) {
            let db = try SQLiteDatabase.inMemory()
            let lib = LibraryRepository(database: db)
            try lib.prepare()
            let source = try lib.saveSource(LibrarySource(name: "双语测试", rootPath: "/bilingual"))
            let work = try lib.upsertWork(WorkRecord(title: "测试", folderPath: "/bilingual/w", folderRelativePath: "w", sourceID: source))
            try lib.replaceTracks(workID: work, tracks: [TrackRecord(workID: work, fileName: "01.wav", filePath: "/bilingual/w/01.wav", fileType: "wav")])
            return (SubtitleRepository(database: db), try lib.tracks(workID: work)[0])
        }
        func plan(_ track: TrackRecord, _ translation: String) -> [ScriptImportAssignment] {
            ScriptImportPlan.make(sections: ScriptSectioner.split("Track1\n00:00:01,000 --> 00:00:06,920\n原文：こんにちは\n译文：" + translation), tracks: [track])
        }
        h.test("自动底稿完整时间和译文可读回、重扫稳定、手改保留") {
            let (repo, track) = try! setup()
            _ = try! repo.importScriptSections(plan(track, "你好呀"), fileName: "双语.pdf", automatically: true)
            let source = try! repo.tracks(forTrackID: track.id)[0]
            _ = try! repo.importScriptSections(plan(track, "您好呀"), fileName: "双语.pdf", automatically: true)
            h.expectEqual(try! repo.tracks(forTrackID: track.id).map(\.id), [source.id], "同一来源")
            let saved = try! repo.activeCues(trackID: track.id)
            h.expectEqual(saved[0].translatedText, "您好呀", "自动底稿可刷新译文")
            h.expectEqual(saved[0].endMS, 6920, "完整句尾持久化")
            h.expectEqual(saved[0].status, .ok, "完整时间状态")
            h.expect(try! repo.versions(subtitleTrackID: source.id)[0].note.contains("完整印刷时间"), "备注不冒称没有时间")
            var edited = saved
            edited[0].translatedText = "人工译文"
            _ = try! repo.insertVersion(subtitleTrackID: source.id, note: "人工修改", isBaseline: false, cues: edited)
            _ = try! repo.importScriptSections(plan(track, "再版翻译"), fileName: "双语.pdf", automatically: true)
            h.expectEqual(try! repo.activeCues(trackID: track.id)[0].translatedText, "人工译文", "手改不覆盖")
            h.expectEqual(try! repo.tracks(forTrackID: track.id).count, 1, "不因新备注重复创建来源")
        }
        h.test("重新导入新识别结果保留旧手动来源和人工版本") {
            let (repo, track) = try! setup()
            let old = try! repo.createTrack(trackID: track.id, kind: .script, language: nil, label: "双语.pdf · 第1轨", cues: [SubtitleCue(startMS: 1000, endMS: 6000, text: "--> 00:00:06,920\nこんにちは\n你好呀", status: .provisional)])
            _ = try! repo.insertVersion(subtitleTrackID: old.track, note: "手改", isBaseline: false, cues: [SubtitleCue(startMS: 1000, endMS: 6000, text: "人工保存文字", translatedText: "人工保存译文")])
            _ = try! repo.importScriptSections(plan(track, "你好呀"), fileName: "双语.pdf")
            h.expectEqual(try! repo.cues(versionID: old.version)[0].text, "--> 00:00:06,920\nこんにちは\n你好呀", "旧基线可追溯")
            h.expectEqual(try! repo.activeCues(trackID: track.id)[0].translatedText, "人工保存译文", "原激活手改仍在")
            h.expectEqual(try! repo.tracks(forTrackID: track.id).count, 2, "新解析结果单独保存，不偷偷覆盖旧稿")
        }
    }
}
