import Foundation
import HibikiCore

func runScriptSuites(_ h: Harness) {

    h.suite("台本解析") {
        h.test("名前「台词」格式") {
            let lines = ScriptParser.parse("男主「あ、そこはだめ……」\n女主「そんなこと言われても」")
            h.expectEqual(lines.count, 2, "两行")
            h.expectEqual(lines[0].speaker, "男主", "说话人")
            h.expectEqual(lines[0].text, "あ、そこはだめ……", "台词去掉引号")
        }

        h.test("名前：台词格式") {
            let lines = ScriptParser.parse("男主：あ、そこはだめ\n女主: えっ")
            h.expectEqual(lines.count, 2, "两行")
            h.expectEqual(lines[0].speaker, "男主", "全角冒号")
            h.expectEqual(lines[0].text, "あ、そこはだめ", "台词")
            h.expectEqual(lines[1].speaker, "女主", "半角冒号")
        }

        h.test("【名前】台词格式") {
            let lines = ScriptParser.parse("【男主】あ、そこはだめ")
            h.expectEqual(lines[0].speaker, "男主", "说话人")
            h.expectEqual(lines[0].text, "あ、そこはだめ", "台词")
        }

        h.test("没有说话人") {
            let lines = ScriptParser.parse("「あ、そこはだめ……」")
            h.expectNil(lines[0].speaker, "无说话人")
            h.expectEqual(lines[0].text, "あ、そこはだめ……", "台词")
        }

        h.test("过滤页码") {
            let lines = ScriptParser.parse("1\n男主「あ」\n- 2 -\n3")
            h.expectEqual(lines.count, 1, "只剩台词")
            h.expectEqual(lines[0].text, "あ", "内容")
        }

        h.test("过滤空行与分隔线") {
            let lines = ScriptParser.parse("\n\n-----\n====\n「あ」\n\n")
            h.expectEqual(lines.count, 1, "只剩一句")
        }

        h.test("整行都是括号说明的丢弃") {
            let lines = ScriptParser.parse("（ドアを叩く音）\n「あ」")
            h.expectEqual(lines.count, 1, "说明被丢")
            h.expectEqual(lines[0].text, "あ", "只剩台词")
        }

        h.test("括号说明保留在台词里（供对齐时剥除）") {
            let lines = ScriptParser.parse("「はあ……（息）……だめ」")
            h.expectEqual(lines.count, 1, "一行")
            h.expect(lines[0].text.contains("（息）"), "括号还在")
        }

        h.test("多行连续台词各自成行") {
            let text = """
            男主「一行目」
            男主「二行目」
            男主「三行目」
            """
            h.expectEqual(ScriptParser.parse(text).count, 3, "三行")
        }

        h.test("行号连续") {
            let lines = ScriptParser.parse("「あ」\n「い」\n「う」")
            h.expectEqual(lines.map(\.index), [0, 1, 2], "行号")
        }
    }

    h.suite("对齐结果转字幕") {
        func aligned(_ index: Int, _ start: Int?, _ end: Int?, _ ratio: Double, _ text: String) -> AlignedScriptLine {
            AlignedScriptLine(
                index: index,
                originalText: text,
                startMS: start,
                endMS: end,
                matchRatio: ratio,
                status: start == nil ? .unaligned : .ok
            )
        }

        h.test("基本转换") {
            let lines = [
                aligned(0, 1000, 3000, 0.95, "あ、そこはだめ"),
                aligned(1, 3500, 5000, 0.9, "そんなこと")
            ]
            let cues = ScriptToCues.build(aligned: lines)
            h.expectEqual(cues.count, 2, "两句")
            h.expectEqual(cues[0].startMS, 1000, "起始")
            h.expectEqual(cues[0].text, "あ、そこはだめ", "文本")
        }

        h.test("未对齐的行被跳过") {
            let lines = [
                aligned(0, 1000, 3000, 0.95, "あ"),
                aligned(1, nil, nil, 0, "い"),
                aligned(2, 5000, 7000, 0.9, "う")
            ]
            let cues = ScriptToCues.build(aligned: lines)
            h.expectEqual(cues.count, 2, "跳过一行")
            h.expectEqual(cues.map(\.text), ["あ", "う"], "内容")
        }

        h.test("低匹配率的行被跳过") {
            let lines = [
                aligned(0, 1000, 3000, 0.95, "あ"),
                aligned(1, 4000, 6000, 0.1, "乱码")
            ]
            let cues = ScriptToCues.build(aligned: lines)
            h.expectEqual(cues.count, 1, "只留高匹配")
        }

        h.test("相邻句不重叠") {
            let lines = [
                aligned(0, 1000, 4000, 0.9, "あ"),
                aligned(1, 3000, 6000, 0.9, "い")   // 与上一句重叠
            ]
            let cues = ScriptToCues.build(aligned: lines)
            h.expect(cues[0].endMS <= cues[1].startMS, "第一句在第二句开始前结束")
        }

        h.test("最后一句封到音频末尾") {
            let lines = [aligned(0, 1000, 3000, 0.9, "あ")]
            let cues = ScriptToCues.build(aligned: lines, totalDurationMS: 10_000)
            h.expectEqual(cues.count, 1, "一句")
            h.expect(cues[0].endMS <= 10_000, "不超过总时长")
        }

        h.test("最短时长保证") {
            let lines = [aligned(0, 1000, 1010, 0.9, "あ")]
            let cues = ScriptToCues.build(aligned: lines)
            h.expect(cues[0].durationMS >= 300, "至少 300ms")
        }

        h.test("空输入返回空") {
            h.expectEqual(ScriptToCues.build(aligned: []).count, 0, "空")
        }

        h.test("统计信息") {
            let lines = [
                aligned(0, 1000, 3000, 0.9, "あ"),
                aligned(1, 4000, 6000, 0.5, "い"),
                aligned(2, nil, nil, 0, "う")
            ]
            let summary = ScriptToCues.summarize(lines)
            h.expectEqual(summary.totalLines, 3, "总行数")
            h.expectEqual(summary.alignedLines, 2, "已对齐")
            h.expectEqual(summary.highConfidenceLines, 1, "高置信")
        }
    }

    // ─────────────────────────────────────────────────────────
    // 端到端：台本 + ASR token → 字幕
    h.suite("台本对齐端到端") {
        h.test("台本能对上 ASR 的时间") {
            let script = """
            男主「あ、そこはだめ……」
            女主「そんなこと言われても」
            男主「もう少しだけ、こうしていよう」
            """
            let lines = ScriptParser.parse(script)
            h.expectEqual(lines.count, 3, "三行台词")

            // 模拟 ASR 输出（带时间的 token）
            let tokens: [TimedToken] = [
                TimedToken(text: "あ、そこはだめ", startMS: 1000, endMS: 3000),
                TimedToken(text: "そんなこと言われても", startMS: 4000, endMS: 6500),
                TimedToken(text: "もう少しだけこうしていよう", startMS: 7000, endMS: 9500)
            ]

            let aligned = ScriptAligner.align(
                scriptLines: ScriptParser.alignableLines(lines),
                tokens: tokens
            )
            let cues = ScriptToCues.build(aligned: aligned, totalDurationMS: 10_000)
            h.expectEqual(cues.count, 3, "三句字幕")
            h.expectEqual(cues[0].text, "あ、そこはだめ……", "保留台本原文（含标点）")
            h.expectEqual(cues[0].startMS, 1000, "起始时间")
            h.expect(cues[0].endMS > cues[0].startMS, "有时长")
        }

        h.test("台本比 ASR 多出内容时也能对上") {
            let lines = ScriptParser.parse("""
            「あ、そこはだめ」
            （ドアを叩く）
            「そんなこと言われても」
            """)
            let tokens: [TimedToken] = [
                TimedToken(text: "あそこはだめ", startMS: 1000, endMS: 3000),
                TimedToken(text: "そんなこと言われても", startMS: 4000, endMS: 6000)
            ]
            let aligned = ScriptAligner.align(
                scriptLines: ScriptParser.alignableLines(lines),
                tokens: tokens
            )
            let cues = ScriptToCues.build(aligned: aligned)
            h.expectEqual(lines.count, 2, "括号说明已被过滤")
            h.expect(cues.count >= 2, "至少两句字幕，实际 \(cues.count)")
        }
    }
}

/// 没有台本时，识别结果直接拼字幕
func runTokenCueSuites(_ h: Harness) {

    h.suite("识别结果拼字幕") {
        func token(_ text: String, _ start: Int, _ end: Int) -> TimedToken {
            TimedToken(text: text, startMS: start, endMS: end)
        }

        h.test("连续词拼成一句") {
            let tokens = [
                token("あ、", 1000, 1300),
                token("そこは", 1300, 1800),
                token("だめ", 1800, 2200)
            ]
            let cues = TokenCueBuilder.build(tokens: tokens)
            h.expectEqual(cues.count, 1, "一句")
            h.expectEqual(cues[0].text, "あ、そこはだめ", "拼起来")
            h.expectEqual(cues[0].startMS, 1000, "起始")
        }

        h.test("长间隔断句") {
            let tokens = [
                token("あ", 1000, 1300),
                token("い", 1300, 1600),
                token("う", 3000, 3400),
                token("え", 3400, 3800)
            ]
            let cues = TokenCueBuilder.build(tokens: tokens)
            h.expectEqual(cues.count, 2, "断成两句，实际 \(cues.count)")
            h.expectEqual(cues[0].text, "あい", "第一句")
            h.expectEqual(cues[1].text, "うえ", "第二句")
        }

        h.test("超长强制断开") {
            var tokens: [TimedToken] = []
            for i in 0..<30 {
                tokens.append(token("あ", i * 500, i * 500 + 450))
            }
            let cues = TokenCueBuilder.build(tokens: tokens, options: .init(maximumCharacters: 10))
            h.expect(cues.count > 1, "被切成多句")
            h.expect(cues.allSatisfy { $0.text.count <= 20 }, "都不太长")
        }

        h.test("太短的分句并入下一句") {
            let tokens = [
                token("あ", 1000, 1100),      // 100ms，太短
                token("い", 2500, 3500)       // 1000ms
            ]
            let cues = TokenCueBuilder.build(tokens: tokens)
            h.expectEqual(cues.count, 1, "合并成一句")
            h.expectEqual(cues[0].text, "あい", "内容合并")
        }

        h.test("句末标点处断句") {
            let tokens = [
                token("あ、そこはだめ。", 1000, 2000),
                token("そんなこと言われても。", 2100, 3000),
                token("ねえ。", 3100, 3500)
            ]
            let cues = TokenCueBuilder.build(tokens: tokens)
            h.expectEqual(cues.count, 3, "按句号断成三句，实际 \(cues.count)")
        }

        h.test("空输入") {
            h.expectEqual(TokenCueBuilder.build(tokens: []).count, 0, "空")
        }

        h.test("乱序 token 会被排序") {
            let tokens = [
                token("う", 3000, 3400),
                token("あ", 1000, 1400)
            ]
            let cues = TokenCueBuilder.build(tokens: tokens)
            h.expectEqual(cues[0].startMS, 1000, "按时间排序")
        }
    }
}

/// 跨语言对齐：中文台本 × 日语音频
func runCrossLanguageSuites(_ h: Harness) {

    h.suite("跨语言对齐（中文台本 + 日语音频）") {
        /// 造一段日语 ASR 结果：两句话，中间停顿 800ms
        func japaneseTokens() -> [TimedToken] {
            [
                TimedToken(text: "ねえ", startMS: 1000, endMS: 1400),
                TimedToken(text: "聞こえてる", startMS: 1400, endMS: 2200),
                TimedToken(text: "こんな", startMS: 3000, endMS: 3400),
                TimedToken(text: "夜更けに", startMS: 3400, endMS: 4200),
                TimedToken(text: "どうしたの", startMS: 4200, endMS: 5200)
            ]
        }

        h.test("识别出停顿边界") {
            let segments = CrossLanguageAligner.segments(from: japaneseTokens(), pauseThresholdMS: 250)
            h.expectEqual(segments.count, 2, "两段，实际 \(segments.count)")
            h.expectEqual(segments[0].startMS, 1000, "第一段起点")
            h.expectEqual(segments[0].endMS, 2200, "第一段终点")
            h.expectEqual(segments[1].startMS, 3000, "第二段起点")
        }

        h.test("中文台词能分到时间") {
            let lines = ["……喂，你听得见吗？", "这么晚了，怎么了？"]
            let aligned = CrossLanguageAligner.align(scriptLines: lines, tokens: japaneseTokens())
            h.expectEqual(aligned.count, 2, "两行都有结果")
            h.expect(aligned.allSatisfy { $0.startMS != nil }, "都拿到了时间")
            h.expect(aligned[0].startMS! < aligned[1].startMS!, "时间递增")
        }

        h.test("时间不重叠") {
            let lines = ["第一句台词内容", "第二句台词内容", "第三句"]
            let aligned = CrossLanguageAligner.align(scriptLines: lines, tokens: japaneseTokens())
            for index in 1..<aligned.count {
                h.expect(
                    aligned[index].startMS! >= aligned[index - 1].endMS!,
                    "第 \(index) 句不与前一句重叠"
                )
            }
        }

        h.test("每句都有最小时长") {
            let lines = ["短", "也很短"]
            let aligned = CrossLanguageAligner.align(scriptLines: lines, tokens: japaneseTokens())
            h.expect(aligned.allSatisfy { ($0.endMS ?? 0) - ($0.startMS ?? 0) >= 400 }, "都不短于 400ms")
        }

        h.test("按字数加权：长句分到更多时间") {
            let lines = ["短", "这是一句非常非常长的台词内容需要更多时间"]
            let aligned = CrossLanguageAligner.align(scriptLines: lines, tokens: japaneseTokens())
            let shortDuration = (aligned[0].endMS! - aligned[0].startMS!)
            let longDuration = (aligned[1].endMS! - aligned[1].startMS!)
            h.expect(longDuration > shortDuration, "长句时间更长（\\(longDuration) > \\(shortDuration)）")
        }

        h.test("没有识别结果时全部标记未对齐") {
            let aligned = CrossLanguageAligner.align(scriptLines: ["中文一", "中文二"], tokens: [])
            h.expectEqual(aligned.count, 2, "两行")
            h.expect(aligned.allSatisfy { $0.status == .unaligned }, "都未对齐")
        }

        h.test("台本为空") {
            h.expectEqual(CrossLanguageAligner.align(scriptLines: [], tokens: japaneseTokens()).count, 0, "空")
        }

        h.test("生成的条目能转成字幕") {
            let lines = ["……喂，你听得见吗？", "这么晚了，怎么了？"]
            let aligned = CrossLanguageAligner.align(scriptLines: lines, tokens: japaneseTokens())
            let cues = ScriptToCues.build(aligned: aligned)
            h.expectEqual(cues.count, 2, "两句字幕")
            h.expectEqual(cues[0].text, "……喂，你听得见吗？", "文字来自台本")
        }
    }

    h.suite("语言判定") {
        h.test("中文台本 + 日语音频 → 跨语言") {
            let tokens = [TimedToken(text: "ねえ、聞こえてる", startMS: 0, endMS: 1000)]
            h.expect(
                ScriptLanguageCheck.isCrossLanguage(scriptText: "喂，你听得见吗？", asrTokens: tokens),
                "判定为跨语言"
            )
        }

        h.test("日文台本 + 日语音频 → 同语言") {
            let tokens = [TimedToken(text: "ねえ、聞こえてる", startMS: 0, endMS: 1000)]
            h.expect(
                !ScriptLanguageCheck.isCrossLanguage(scriptText: "ねえ、聞こえてる？", asrTokens: tokens),
                "判定为同语言"
            )
        }

        h.test("假名比例计算") {
            h.expect(ScriptLanguageCheck.kanaRatio("あいうえお") > 0.9, "全假名")
            h.expect(ScriptLanguageCheck.kanaRatio("你好世界") < 0.01, "全汉字")
        }
    }
}

/// 真实台本里的噪声处理
func runScriptNoiseSuites(_ h: Harness) {

    h.suite("台本噪声过滤") {
        h.test("章节标题被过滤") {
            let text = "■主水 Ash 様 自由谈话\n我是主水Ash，就是这样啦。\n●第二段\n第二段的内容"
            let lines = ScriptParser.parse(text)
            h.expectEqual(lines.count, 2, "只剩两句台词，实际 \(lines.count)")
            h.expectEqual(lines[0].text, "我是主水Ash，就是这样啦。", "第一句")
        }

        h.test("结束标记被过滤") {
            let lines = ScriptParser.parse("「最后一句」\nEND")
            h.expectEqual(lines.count, 1, "END 被丢掉")
        }

        h.test("正常的书名号内容不被误判为标题") {
            let lines = ScriptParser.parse("■短标题\n这是台词内容比较长的一句话不应该被当成标题")
            h.expectEqual(lines.count, 1, "只丢标题")
            h.expect(lines[0].text.hasPrefix("这是台词"), "保留的是台词")
        }
    }
}

/// 合集台本切分
func runScriptSectionSuites(_ h: Harness) {

    h.suite("整部台本初步匹配与无时间正文") {
        func track(_ id: Int64, _ name: String) -> TrackRecord {
            TrackRecord(id: id, workID: 1, fileName: name, filePath: "/w/\(name)", fileType: "wav")
        }
        h.test("轨号配对不受曲目排列影响，支持全角与大写") {
            let sections = ScriptSectioner.split("TRACK１ 第一段\n「あ」\ntrack2 第二段\n「い」")
            let plan = ScriptImportPlan.make(sections: sections, tracks: [track(22, "TRACK２.wav"), track(11, "Tr１.wav")])
            h.expectEqual(plan.compactMap(\.trackID), [11, 22], "按轨号")
            h.expectNil(ScriptSectioner.trackNumber(fromFileName: "Track1000.wav"), "不截断四位数")
            h.expectNil(ScriptSectioner.parseMarker("TRACK1000"), "段落标记不截断")
        }
        h.test("同一轨号有多个音频版本时保持未匹配") {
            let sections = ScriptSectioner.split("track1\n「あ」")
            let plan = ScriptImportPlan.make(sections: sections, tracks: [track(1, "Track1 有SE.wav"), track(2, "Track1 无SE.wav")])
            h.expectNil(plan.first?.trackID, "不猜版本")
        }
        h.test("同名但编码不同的曲目各得一段，音效目录不同必须手选") {
            let section = ScriptSectioner.split("TRACK1\n文本")
            func recording(_ id: Int64, _ path: String) -> TrackRecord {
                let url = URL(fileURLWithPath: path)
                return TrackRecord(id: id, workID: 1, fileName: url.lastPathComponent,
                                   filePath: path, fileType: url.pathExtension)
            }
            let pair = [recording(9, "/work/wav/Track1.wav"), recording(3, "/work/mp3/Track1.mp3")]
            let shared = ScriptImportPlan.make(sections: section, tracks: pair)
            h.expectEqual(shared.compactMap(\.trackID), [9, 3], "格式子目录可共享")
            h.expectEqual(Set(shared.map(\.id)).count, 2, "手动配对表的两行标识独立")
            let other = recording(4, "/work/无SE/Track1.flac")
            let ambiguous = ScriptImportPlan.make(sections: section, tracks: [pair[0], other])
            h.expect(ambiguous.allSatisfy { $0.trackID == nil }, "相同编号不同录音不匹配")
        }
        h.test("重复段落轨号不自动选择第一段") {
            let sections = ScriptSectioner.split("track1\n「あ」\ntrack1\n「い」")
            let plan = ScriptImportPlan.make(sections: sections, tracks: [track(1, "Track1.wav")])
            h.expect(plan.allSatisfy { $0.trackID == nil }, "两段都待确认")
            h.expectNil(ScriptSectioner.section(forTrackNumber: 1, in: sections), "单轨生成也不猜")
        }
        h.test("无标记台本仅在整部作品只有一曲时自动匹配") {
            let sections = ScriptSectioner.split("第一句\n第二句")
            let one = ScriptImportPlan.make(sections: sections, tracks: [track(8, "序章.wav")])
            let many = ScriptImportPlan.make(sections: sections, tracks: [track(8, "序章.wav"), track(9, "本篇.wav")])
            h.expectEqual(one.first?.trackID, 8, "唯一曲目")
            h.expectNil(many.first?.trackID, "多曲不按顺序猜")
        }
        h.test("整本轨号过滤封面，两份单曲台本读曲名与文件名轨号") {
            let tracks = [track(1, "01 morning.wav"), track(2, "02 evening.wav")]
            let book = WorkScriptMatching(text: "扉页\n翻译人员\nTr01 一\n0:01 甲\nTr02 二\n0:02 乙",
                                          fileName: "正片台本.pdf", candidates: tracks)
            h.expectEqual(book.suggestedAssignments.compactMap(\.trackID), [1, 2], "封面不占用音轨")
            h.expectEqual(book.assignableSections.flatMap(\.lines).map(\.text), ["甲", "乙"], "手选保存的正文仅含章节台词")
            func ids(_ name: String, _ candidates: [TrackRecord]) -> [Int64] {
                WorkScriptMatching(text: "正文一行", fileName: name, candidates: candidates).suggestedAssignments.compactMap(\.trackID)
            }
            h.expectEqual(ids("Track２ 台本.pdf", tracks), [2], "文件名标轨，正文无标轨")
            h.expectEqual(ids("01 简体字台本.txt", tracks), [1], "数字和台本后缀")
            h.expectEqual(ids("02 evening_簡体字台本.pdf", tracks), [2], "相同曲名与明确的译本后缀")
            h.expect(ids("Track1–2 台本.pdf", tracks).isEmpty, "跨轨范围不能认作单曲")
            h.expect(ids("Track 1 & Track 2 台本.pdf", tracks).isEmpty, "书写两个轨号也不只配给第一轨")
            h.expect(ids("Track2 台本.txt", tracks + [track(3, "02 another.wav")]).isEmpty, "多组有同号时保留手选")
            h.expect(ids("Tr99 台本.txt", [tracks[0]]).isEmpty, "明确轨号不一致时也不能配唯一曲目")
        }
        h.test("按点击顺序分给指定音轨，无分轨标题必须明确选第二轨的起始行") {
            let chapters = OrderedScriptMapping(sections: ScriptSectioner.split("说明\nTRACK3\n第三章\nTRACK8\n第八章"))
            let pairs = chapters.assignments(trackIDs: [77, 10], starts: [:])
            h.expectEqual(pairs?.compactMap(\.trackID), [77, 10], "点选顺序覆盖原轨号")
            h.expectEqual(pairs?.compactMap { $0.section.lines.first?.text }, ["第三章", "第八章"], "章节预览不包含卷首说明")
            let body = OrderedScriptMapping(sections: ScriptSectioner.split("甲：第一行\n甲：第二行\n甲：第三行\n甲：第四行"))
            h.expectNil(body.assignments(trackIDs: [22, 11], starts: [:]), "缺少分界不拆")
            h.expectNil(body.assignments(trackIDs: [22, 11], starts: [11: 4]), "曲尾越界不拆")
            h.expectNil(body.assignments(trackIDs: [22, 22], starts: [22: 1]), "禁止重复指定一轨")
            let manual = body.assignments(trackIDs: [22, 11], starts: [11: 2])
            h.expectEqual(manual?.map { $0.section.lines.map(\.text) }, [["第一行", "第二行"], ["第三行", "第四行"]], "两轨各得自己的行")
            h.expectEqual(body.assignments(trackIDs: [12], starts: [:])?.first?.section.lines.count, 4, "单曲不拆分")
            let timed = OrderedScriptMapping(sections: ScriptSectioner.split("TR1\n0:01 甲\n0:04.250 乙\nTR2\n0:01 丙"))
            let merged = timed.assignments(trackIDs: [12], starts: [:])![0].section
            h.expect(ScriptImportPlan.cues(for: merged).allSatisfy { !$0.hasTiming }, "拼合多章不混用各章本地时钟")
            h.expectEqual(merged.lines.map(\.text), ["[0:01] 甲", "[00:04.250] 乙", "[0:01] 丙"], "印刷时间仍可供手工校准")
            let exact = timed.assignments(trackIDs: [11, 12], starts: [:])!
            h.expectEqual(exact[1].section.lines.first?.printedStartMS, 1000, "整章配一轨保留起点")
            let differentCuts = timed.assignments(trackIDs: [11, 12, 13], starts: [12: 1, 13: 2])!
            h.expect(differentCuts[0].section.lines.first?.printedStartMS == nil, "人为剖分不臆测原时间轴")
            h.expectEqual(differentCuts[2].section, timed.sections[1], "最后一段正好完整则保持原章节和原时间")
        }
        h.test("正文保留说话人和顺序，文字修改不虚构时间") {
            let section = ScriptSectioner.split("Track1\n甲：第一句\n乙：第二句")[0]
            let cues = ScriptImportPlan.untimedCues(for: section)
            h.expectEqual(cues.map(\.speaker), ["甲", "乙"], "说话人")
            h.expectEqual(cues.map(\.text), ["第一句", "第二句"], "全文顺序")
            h.expect(cues.allSatisfy { $0.status == .untimed && !$0.hasTiming }, "明确无时间")
            let edited = CueEditor.settingText(cues, at: 1, to: "修正第二句")
            h.expectEqual(edited[1].status, .untimed, "只改文字仍无时间")
            h.expectEqual(CueEditor.shiftAll(edited, by: 500)[1].endMS, 0, "整体平移不创建时间")
            h.expectNil(SubtitleLocator(cues: edited).cue(at: 0), "不会匹配零秒")
            h.expectNil(SubtitleLocator(cues: edited).next(after: -1), "不会成为下一句")
            let timed = CueEditor.settingRange(edited, at: 1, startMS: 4200, endMS: 5600)
            h.expect(timed[1].hasTiming, "人工设置区间后可用")
            h.expectEqual(SubtitleLocator(cues: timed).cue(at: 4500)?.index, 1, "保留正文下标")
            h.expectEqual(timed[0].status, .untimed, "其它行保持无时间")
        }
    }

    h.suite("根目录台本与混合特典") {
        func track(_ id: Int, _ relative: String) -> TrackRecord {
            let url = URL(fileURLWithPath: "/fixture/" + relative)
            return TrackRecord(id: Int64(id), workID: 1, fileName: url.lastPathComponent, filePath: url.path,
                               relativePath: relative, fileType: url.pathExtension)
        }
        let voices = (1...12).map { track($0, String(format: "wav/%02d_短语音.wav", $0)) }
        let story = [track(13, "SEあり/【早期購入特典】本編後日談.mp3"), track(14, "SEあり/【早期購入特典】本編後日談.wav")]
        let voiceTitle = "早期購入特典_ボイスメッセージ_簡体字台本.pdf".decomposedStringWithCanonicalMapping
        let bareNumbers = (1...12).map { "\($0)\n甲：第\($0)段" }.joined(separator: "\n")
        func matches(_ text: String, _ title: String, _ tracks: [TrackRecord]) -> [ScriptImportAssignment] {
            let match = WorkScriptMatching(text: text, fileName: title, candidates: tracks)
            return ScriptImportPlan.make(sections: match.sections, tracks: match.tracks)
        }
        h.test("一份有裸序号的语音台本和一份无序号的后日谈共存") {
            let mixed = voices + story
            let old = ScriptImportPlan.make(sections: ScriptSectioner.split(bareNumbers), tracks: mixed)
            h.expect(old.compactMap(\.trackID).isEmpty, "只用整目录与 Track 标记无法匹配")
            let spoken = matches(bareNumbers, voiceTitle, mixed)
            h.expectEqual(spoken.compactMap(\.trackID), voices.map(\.id), "分解形式的日语文件名，12 段各入正确录音")
            h.expectEqual(spoken.map { $0.section.lines[0].text }, (1...12).map { "第\($0)段" }, "每条录音正文正确")
            let single = matches("甲：故事开头", "早期購入特典_簡体字台本.pdf", mixed)
            h.expectEqual(single.compactMap(\.trackID), story.map(\.id), "无轨号的同录音两种格式")
        }
        h.test("两组号码都符合、缺号、页码或特典名有歧义时留待手选") {
            let another = (1...12).map { track(20 + $0, "另一本/\($0)_录音.wav") }
            for bad in [voices + story + another, Array(voices.dropLast()) + story] {
                h.expect(matches(bareNumbers, voiceTitle, bad).compactMap(\.trackID).isEmpty, "编号无法唯一证明时不分配")
            }
            h.expect(matches(bareNumbers, "普通资料.pdf", voices + story).compactMap(\.trackID).isEmpty, "普通说明书页码不能拆轨")
            let extra = track(15, "SEあり/【早期購入特典】第二个故事.mp3")
            h.expect(matches("甲：正文", "早期購入特典_簡体字台本.pdf", voices + story + [extra]).compactMap(\.trackID).isEmpty, "同标识但录音不唯一")
            h.expect(matches("甲：正文", "早期購入特典_另一个作品_簡体字台本.pdf", voices + story).compactMap(\.trackID).isEmpty, "部分标题相同不能猜")
        }
    }

    h.suite("不同语种的整本 PDF") {
        func edition(_ path: String, _ digest: String, _ numbers: Set<Int> = [1, 2]) -> ScriptEdition {
            ScriptEdition(path: path, digest: digest, tracks: numbers)
        }
        let root = edition("簡体中文_书.pdf", "zh")
        let chinese = edition("RJ/合集/language/簡体中文_书.pdf", "zh")
        let english = edition("RJ/合集/language/English_work.pdf", "en")
        let korean = edition("RJ/合集/language/韓国語_本.pdf", "ko")
        h.test("相同中文副本、三种语言及不同标题") {
            let selected = ScriptEdition.selection(from: [english, root, korean, chinese])
            h.expectEqual(selected, [chinese.path, english.path, korean.path], "每个译本只有一份")
            h.expectEqual(ScriptEdition.selection(from: [chinese, english, korean, root]), selected, "遍历顺序无影响")
            h.expect(chinese.preference < english.preference, "简体优先")
        }
        h.test("同语不同稿、编号不一致或无翻译目录仍需人工复核") {
            let alternative = edition("RJ/合集/language/英語_other.pdf", "other")
            h.expect(ScriptEdition.selection(from: [chinese, english, alternative]).isEmpty, "同语言冲突")
            h.expect(ScriptEdition.selection(from: [chinese, edition(english.path, "en", [2])]).isEmpty, "疑似别部")
            h.expect(ScriptEdition.selection(from: [root, edition("English_work.pdf", "en")]).isEmpty, "没有证据的同号文件")
            let unmarked = edition("RJ/合集/language/other.pdf", "???")
            h.expect(ScriptEdition.selection(from: [chinese, unmarked]).isEmpty, "不明语种")
            let traditional = edition("繁體中文_书.pdf", "hant")
            h.expectEqual(ScriptEdition.selection(from: [root, traditional]).count, 2, "同名简繁台本兼容")
        }
        h.test("按纸面起点生成可校对的区间，保留换行、过滤署名、超界保留原文") {
            let sections = ScriptSectioner.split("""
            tr02 台本
            0:01 第一段（标题）
            用我的「台词」作续行。
            CV：演员
            0:04 第二段
            3:50 第三段
            11:55 录音外的一句
            总时长：20分55秒
            下一位角色资料
            tr03 新段落
            开场白
            """)
            let lines = sections[0].lines
            h.expectEqual(lines.compactMap(\.printedStartMS), [1000, 4000, 230000, 715000], "只保留实印时间")
            h.expectEqual(lines[0].text, "第一段（标题）\n用我的「台词」作续行。", "正文含续行和原来括号")
            h.expect(lines.allSatisfy { $0.speaker == nil }, "分钟、CV 或行中引号不算人名")
            let cues = ScriptImportPlan.cues(for: sections[0], durationMS: 231000)
            h.expectEqual(cues.map(\.endMS), [4000, 9000, 231000, 0], "下一条、五秒封顶和音频末尾")
            h.expectEqual(cues.map(\.status), [.provisional, .provisional, .provisional, .untimed], "可区分初步时间")
            h.expect(cues[3].text.hasPrefix("[11:55]"), "保留印刷值，方便核对")
            h.expect(ScriptImportPlan.cues(for: sections[1]).allSatisfy { !$0.hasTiming }, "纯文字仍无时间")
        }
        h.test("时间可靠时重排 PDF 取字次序，重复或无时间不猜") {
            let section = ScriptSectioner.split("tr17\n01:06 第二段\n5:12 第三段\n0:01 第一段")[0]
            h.expectEqual(section.lines.compactMap(\.printedStartMS), [1000, 66000, 312000], "按印刷时间还原顺序")
            let duplicate = ScriptSectioner.split("tr1\n前言\n0:01 甲\n0:01 乙\n0:02 丙")[0]
            let cues = ScriptImportPlan.cues(for: duplicate)
            h.expectEqual(cues.map(\.status), [.untimed, .untimed, .untimed, .provisional], "没有时间或时间冲突仍可读")
        }
    }

    h.suite("合集台本切分") {
        h.test("识别全角数字的 TRACK 标记") {
            let marker = ScriptSectioner.parseMarker("■TRACK１ 不能吃青梅竹马做的料理")
            h.expectNotNil(marker, "是标记行")
            h.expectEqual(marker?.number, 1, "轨道号（全角１转成 1）")
            h.expectEqual(marker?.title, "不能吃青梅竹马做的料理", "标题")
        }

        h.test("识别其他标记写法") {
            h.expectEqual(ScriptSectioner.parseMarker("●Track 3：标题")?.number, 3, "Track 3")
            h.expectEqual(ScriptSectioner.parseMarker("■トラック２")?.number, 2, "トラック２")
            h.expectEqual(ScriptSectioner.parseMarker("第2話 続き")?.number, 2, "第2話")
        }

        h.test("普通台词不是标记") {
            h.expectNil(ScriptSectioner.parseMarker("庵：「哎呀，真的好久不见了呢"), "台词")
            h.expectNil(ScriptSectioner.parseMarker("我只是随便说说"), "普通句子")
        }

        h.test("按标记切成多段") {
            let text = """
            ■TRACK１ 第一轨的标题
            庵：「第一轨第一句
            庵：「第一轨第二句
            ■TRACK２ 第二轨的标题
            庵：「第二轨第一句
            """
            let sections = ScriptSectioner.split(text)
            h.expectEqual(sections.count, 2, "两段，实际 \(sections.count)")
            h.expectEqual(sections[0].trackNumber, 1, "第一段轨道号")
            h.expectEqual(sections[0].title, "第一轨的标题", "第一段标题")
            h.expectEqual(sections[0].lines.count, 2, "第一段两句")
            h.expectEqual(sections[1].trackNumber, 2, "第二段轨道号")
            h.expectEqual(sections[1].lines.count, 1, "第二段一句")
        }

        h.test("没有标记时只有一段") {
            let sections = ScriptSectioner.split("「第一句」\n「第二句」")
            h.expectEqual(sections.count, 1, "一段")
            h.expectNil(sections[0].trackNumber, "没有轨道号")
            h.expectEqual(sections[0].lines.count, 2, "两句")
        }

        h.test("说话人前缀被正确拆出") {
            let sections = ScriptSectioner.split("■TRACK１\n庵：「哎呀，真的好久不见了呢")
            h.expectEqual(sections[0].lines.first?.speaker, "庵", "说话人")
            h.expect(sections[0].lines.first?.text.hasPrefix("哎呀") == true, "台词")
        }

        h.test("从文件名读轨道号") {
            h.expectEqual(ScriptSectioner.trackNumber(fromFileName: "Tr1_幼馴染の料理は食べてはいけない.wav"), 1, "Tr1")
            h.expectEqual(ScriptSectioner.trackNumber(fromFileName: "03. エピローグ.mp3"), 3, "03.")
            h.expectEqual(ScriptSectioner.trackNumber(fromFileName: "track5.mp3"), 5, "track5")
            h.expectNil(ScriptSectioner.trackNumber(fromFileName: "プロローグ.wav"), "没有号")
        }

        h.test("按轨道号找到对应段落") {
            let text = "■TRACK１ 甲\n「一」\n■TRACK２ 乙\n「二」\n■TRACK３ 丙\n「三」"
            let sections = ScriptSectioner.split(text)
            h.expectEqual(ScriptSectioner.section(forTrackNumber: 2, in: sections)?.title, "乙", "第二段")
            h.expectNil(ScriptSectioner.section(forTrackNumber: 9, in: sections), "找不到")
        }

        h.test("标记没有轨道号时按顺序对应") {
            let sections = [
                ScriptSection(index: 0, trackNumber: nil, title: "甲", lines: []),
                ScriptSection(index: 1, trackNumber: nil, title: "乙", lines: [])
            ]
            h.expectEqual(ScriptSectioner.section(forTrackNumber: 2, in: sections)?.title, "乙", "按顺序")
        }
    }
}
