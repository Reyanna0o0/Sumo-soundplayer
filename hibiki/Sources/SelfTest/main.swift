import Foundation
import HibikiCore

// 关掉 stdout 缓冲，这样崩溃也能看到最后跑到哪
setvbuf(stdout, nil, _IONBF, 0)

let h = Harness()

// ─────────────────────────────────────────────────────────────
h.suite("SubtitleTime 解析与格式化") {
    h.test("标准格式") {
        h.expectEqual(SubtitleTime.parseMilliseconds("00:00:01,000"), 1000, "SRT 逗号")
        h.expectEqual(SubtitleTime.parseMilliseconds("00:00:01.000"), 1000, "VTT 点")
        h.expectEqual(SubtitleTime.parseMilliseconds("01:02:03,456"), 3_723_456, "带小时")
        h.expectEqual(SubtitleTime.parseMilliseconds("0:00:01.23"), 1230, "ASS 厘秒")
        h.expectEqual(SubtitleTime.parseMilliseconds("02:03"), 123_000, "无小数")
        h.expectEqual(SubtitleTime.parseMilliseconds("02:03.45"), 123_450, "两段带小数")
    }

    h.test("小数位数") {
        h.expectEqual(SubtitleTime.parseMilliseconds("00:00:01.5"), 1500, "1 位")
        h.expectEqual(SubtitleTime.parseMilliseconds("00:00:01.50"), 1500, "2 位")
        h.expectEqual(SubtitleTime.parseMilliseconds("00:00:01.500"), 1500, "3 位")
        h.expectEqual(SubtitleTime.parseMilliseconds("00:00:01.1234"), 1123, "4 位舍")
        h.expectEqual(SubtitleTime.parseMilliseconds("00:00:01.1236"), 1124, "4 位入")
    }

    h.test("非法输入返回 nil") {
        h.expectNil(SubtitleTime.parseMilliseconds(""), "空串")
        h.expectNil(SubtitleTime.parseMilliseconds("abc"), "非数字")
        h.expectNil(SubtitleTime.parseMilliseconds("00:99:00,000"), "分钟超界")
        h.expectNil(SubtitleTime.parseMilliseconds("00:00:99,000"), "秒超界")
        h.expectNil(SubtitleTime.parseMilliseconds("1:2:3:4"), "段数错误")
    }

    h.test("格式化各格式") {
        let ms = 3_723_456
        h.expectEqual(SubtitleTime.srt(ms), "01:02:03,456", "srt")
        h.expectEqual(SubtitleTime.vtt(ms), "01:02:03.456", "vtt")
        h.expectEqual(SubtitleTime.lrc(ms), "[62:03.45]", "lrc")
        h.expectEqual(SubtitleTime.ass(ms), "1:02:03.45", "ass")
        h.expectEqual(SubtitleTime.clock(ms), "1:02:03", "clock")
        h.expectEqual(SubtitleTime.clockWithMilliseconds(ms), "1:02:03.456", "clock ms")
    }

    h.test("一小时以内") {
        h.expectEqual(SubtitleTime.clock(83_000), "1:23", "clock")
        h.expectEqual(SubtitleTime.clockWithMilliseconds(83_456), "01:23.456", "clock ms")
    }

    h.test("往返一致") {
        for ms in [0, 1, 999, 1000, 59_999, 3_599_999, 7_200_001] {
            h.expectEqual(SubtitleTime.parseMilliseconds(SubtitleTime.srt(ms)), ms, "srt \(ms)")
            h.expectEqual(SubtitleTime.parseMilliseconds(SubtitleTime.vtt(ms)), ms, "vtt \(ms)")
        }
    }

    h.test("负数钳到 0") {
        h.expectEqual(SubtitleTime.srt(-5000), "00:00:00,000", "负数")
    }

    h.test("微调显示") {
        h.expectEqual(SubtitleTime.signedSeconds(500), "+500ms", "正 ms")
        h.expectEqual(SubtitleTime.signedSeconds(-1500), "−1.5s", "负 s")
    }
}

// ─────────────────────────────────────────────────────────────
h.suite("SRT 解析") {
    h.test("基本的两个块") {
        let srt = "1\n00:00:01,000 --> 00:00:04,000\nあ、そこはだめ\n\n2\n00:00:05,500 --> 00:00:08,000\nそんなこと言われたら\n"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues.count, 2, "条目数")
        h.expectEqual(r.cues[0].startMS, 1000, "start")
        h.expectEqual(r.cues[0].endMS, 4000, "end")
        h.expectEqual(r.cues[0].text, "あ、そこはだめ", "text")
        h.expectEqual(r.cues[1].startMS, 5500, "第二条 start")
    }

    h.test("块之间没有空行") {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n第一句\n2\n00:00:03,000 --> 00:00:04,000\n第二句"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues.count, 2, "条目数")
        h.expectEqual(r.cues[1].text, "第二句", "第二条 text")
    }

    h.test("逗号换成点") {
        let srt = "1\n00:00:01.000 --> 00:00:02.500\nテスト"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].endMS, 2500, "end")
    }

    h.test("去标签") {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n{\\an8}<i>斜体</i> と <font color=\"red\">赤</font>"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues[0].text, "斜体 と 赤", "text")
    }

    h.test("多行正文") {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n一行目\n二行目"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues[0].text, "一行目\n二行目", "text")
    }

    h.test("说话人提取") {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\n太郎: こんにちは"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues[0].speaker, "太郎", "speaker")
    }

    h.test("长句不误判说话人") {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nこれは長い文章なので話者ではない: 本当にそう思う"
        let r = SRTSubtitleParser.parse(srt)
        h.expectNil(r.cues[0].speaker, "speaker")
    }

    h.test("时间倒置自动修正") {
        let srt = "1\n00:00:05,000 --> 00:00:04,000\n逆向き"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues[0].endMS, 6000, "end")
        h.expect(!r.warnings.isEmpty, "应有警告")
    }

    h.test("CRLF 与 BOM") {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nテスト\r\n"
        let r = SRTSubtitleParser.parse(srt)
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].text, "テスト", "text")
    }

    h.test("空输入") {
        h.expect(SRTSubtitleParser.parse("").cues.isEmpty, "应为空")
    }
}

// ─────────────────────────────────────────────────────────────
h.suite("WebVTT 解析") {
    h.test("带头部") {
        let vtt = "WEBVTT\nKind: captions\nLanguage: ja\n\n00:00:01.000 --> 00:00:04.000\nあ、そこはだめ\n\n00:00:05.000 --> 00:00:08.000\nそんなこと"
        let r = WebVTTSubtitleParser.parse(vtt)
        h.expectEqual(r.cues.count, 2, "条目数")
        h.expectEqual(r.metadata["Language"], "ja", "Language")
        h.expectEqual(r.cues[0].text, "あ、そこはだめ", "text")
    }

    h.test("跳过 NOTE") {
        let vtt = "WEBVTT\n\nNOTE これはコメント\n\n00:00:01.000 --> 00:00:02.000\n本文"
        let r = WebVTTSubtitleParser.parse(vtt)
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].text, "本文", "text")
    }

    h.test("带标识行的 cue") {
        let vtt = "WEBVTT\n\ncue-1\n00:00:01.000 --> 00:00:02.000\n識別子つき"
        let r = WebVTTSubtitleParser.parse(vtt)
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].text, "識別子つき", "text")
    }

    h.test("v 标签说话人") {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<v 太郎>こんにちは</v>"
        let r = WebVTTSubtitleParser.parse(vtt)
        h.expectEqual(r.cues[0].speaker, "太郎", "speaker")
        h.expectEqual(r.cues[0].text, "こんにちは", "text")
    }

    h.test("cue settings 被忽略") {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000 align:start position:10%\n本文"
        let r = WebVTTSubtitleParser.parse(vtt)
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].startMS, 1000, "start")
        h.expectEqual(r.cues[0].endMS, 2000, "end")
    }

    h.test("实体解码") {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nA &amp; B &lt;3"
        let r = WebVTTSubtitleParser.parse(vtt)
        h.expectEqual(r.cues[0].text, "A & B <3", "text")
    }
}

// ─────────────────────────────────────────────────────────────
h.suite("LRC 解析") {
    h.test("基本与元信息") {
        let lrc = "[ti:テスト曲]\n[ar:誰か]\n[00:01.00]あ、そこはだめ\n[00:03.50]そんなこと"
        let r = LRCSubtitleParser.parse(lrc)
        h.expectEqual(r.cues.count, 2, "条目数")
        h.expectEqual(r.metadata["ti"], "テスト曲", "ti")
        h.expectEqual(r.cues[0].startMS, 1000, "start0")
        h.expectEqual(r.cues[1].startMS, 3500, "start1")
        h.expectEqual(r.cues[0].endMS, 3500, "结束时间靠下一条推")
        h.expectEqual(r.cues[1].endMS, 3500 + LRCSubtitleParser.defaultTrailingDurationMS, "最后一条默认时长")
    }

    h.test("一行多个时间标签") {
        let lrc = "[00:01.00][00:10.00]サビ\n[00:05.00]Aメロ"
        let r = LRCSubtitleParser.parse(lrc)
        h.expectEqual(r.cues.count, 3, "条目数")
        h.expectEqual(r.cues.map(\.startMS), [1000, 5000, 10000], "时间序列")
        h.expectEqual(r.cues.map(\.text), ["サビ", "Aメロ", "サビ"], "文本序列")
    }

    h.test("正 offset") {
        let r = LRCSubtitleParser.parse("[offset:500]\n[00:01.00]ずらす")
        h.expectEqual(r.cues[0].startMS, 1500, "start")
    }

    h.test("负 offset") {
        let r = LRCSubtitleParser.parse("[offset:-300]\n[00:01.00]ずらす")
        h.expectEqual(r.cues[0].startMS, 700, "start")
    }

    h.test("Enhanced LRC 行内时间戳") {
        let r = LRCSubtitleParser.parse("[00:01.00]<00:01.00>あ<00:01.50>そこ")
        h.expectEqual(r.cues[0].text, "あそこ", "text")
    }

    h.test("毫秒精度") {
        let r = LRCSubtitleParser.parse("[00:01.234]精密")
        h.expectEqual(r.cues[0].startMS, 1234, "start")
    }

    h.test("只有元信息") {
        let r = LRCSubtitleParser.parse("[ti:]タイトルだけ")
        h.expect(r.cues.isEmpty, "应为空")
        h.expect(!r.warnings.isEmpty, "应有警告")
    }
}

// ─────────────────────────────────────────────────────────────
h.suite("ASS / SSA 解析") {
    h.test("标准 v4+ 格式") {
        let ass = """
        [Script Info]
        Title: テスト
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Arial,20

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.50,Default,太郎,0,0,0,,{\\pos(10,20)}あ、そこはだめ
        Dialogue: 0,0:00:04.00,0:00:06.00,Default,,0,0,0,,二行目
        Comment: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,これはコメント
        """
        let r = ASSSubtitleParser.parse(ass)
        h.expectEqual(r.format, .ass, "format")
        h.expectEqual(r.metadata["Title"], "テスト", "Title")
        h.expectEqual(r.cues.count, 2, "Comment 不应收录")
        h.expectEqual(r.cues[0].startMS, 1000, "start")
        h.expectEqual(r.cues[0].endMS, 3500, "end")
        h.expectEqual(r.cues[0].text, "あ、そこはだめ", "text")
        h.expectEqual(r.cues[0].speaker, "太郎", "speaker")
        h.expectNil(r.cues[1].speaker, "Default 不算说话人")
    }

    h.test("正文含逗号不被切碎") {
        let ass = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,一つ目, 二つ目, 三つ目"
        let r = ASSSubtitleParser.parse(ass)
        h.expectEqual(r.cues[0].text, "一つ目, 二つ目, 三つ目", "text")
    }

    h.test("\\\\N 变成换行") {
        let ass = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,上\\N下"
        let r = ASSSubtitleParser.parse(ass)
        h.expectEqual(r.cues[0].text, "上\n下", "text")
    }

    h.test("SSA 识别") {
        let ssa = """
        [Script Info]
        ScriptType: v4.00

        [V4 Styles]
        Format: Name, Fontname

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,SSA本文
        """
        let r = ASSSubtitleParser.parse(ssa)
        h.expectEqual(r.format, .ssa, "format")
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].text, "SSA本文", "text")
    }

    h.test("字段顺序被调换") {
        let ass = "[Events]\nFormat: Start, End, Text, Style, Name\nDialogue: 0:00:02.00,0:00:04.00,本文です,Default,花子"
        let r = ASSSubtitleParser.parse(ass)
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].startMS, 2000, "start")
        h.expectEqual(r.cues[0].text, "本文です", "text")
        h.expectEqual(r.cues[0].speaker, "花子", "speaker")
    }
}

// ─────────────────────────────────────────────────────────────
h.suite("SAMI 解析") {
    h.test("基本的 SYNC 打点") {
        let smi = "<SAMI><BODY>\n<SYNC Start=1000><P Class=KRCC>あ、そこは\n<SYNC Start=3000><P Class=KRCC>&nbsp;\n<SYNC Start=4000><P Class=KRCC>そんなこと\n<SYNC Start=7000><P Class=KRCC>&nbsp;\n</BODY></SAMI>"
        let r = SMISubtitleParser.parse(smi)
        h.expectEqual(r.cues.count, 2, "条目数")
        h.expectEqual(r.cues[0].startMS, 1000, "start")
        h.expectEqual(r.cues[0].endMS, 3000, "空内容作为结束点")
        h.expectEqual(r.cues[0].text, "あ、そこは", "text")
        h.expectEqual(r.cues[1].startMS, 4000, "第二条 start")
        h.expectEqual(r.cues[1].endMS, 7000, "第二条 end")
    }

    h.test("没有 SYNC") {
        let r = SMISubtitleParser.parse("<html><body>ただのHTML</body></html>")
        h.expect(r.cues.isEmpty, "应为空")
        h.expect(!r.warnings.isEmpty, "应有警告")
    }

    h.test("BR 变化行") {
        let smi = "<SYNC Start=0><P Class=KRCC>上<BR>下\n<SYNC Start=2000><P Class=KRCC>&nbsp;"
        let r = SMISubtitleParser.parse(smi)
        h.expectEqual(r.cues[0].text, "上\n下", "text")
    }
}

// ─────────────────────────────────────────────────────────────
h.suite("格式嗅探与分发") {
    h.test("嗅探 VTT") {
        h.expectEqual(SubtitleParser.detectFormat("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx"), .vtt, "vtt")
    }
    h.test("嗅探 SRT") {
        h.expectEqual(SubtitleParser.detectFormat("1\n00:00:01,000 --> 00:00:02,000\nx"), .srt, "srt")
    }
    h.test("嗅探 ASS") {
        h.expectEqual(SubtitleParser.detectFormat("[Script Info]\n[Events]\nDialogue: ..."), .ass, "ass")
    }
    h.test("嗅探 SMI") {
        h.expectEqual(SubtitleParser.detectFormat("<SAMI><BODY><SYNC Start=0>"), .smi, "smi")
    }
    h.test("嗅探 LRC") {
        h.expectEqual(SubtitleParser.detectFormat("[00:01.00]あ\n[00:02.00]い"), .lrc, "lrc")
    }
    h.test("无法识别") {
        h.expectNil(SubtitleParser.detectFormat("ただのメモです\n二行目"), "unknown")
    }
    h.test("从文件名推断") {
        h.expectEqual(SubtitleParser.detectFormat(fromFileName: "作品.ja.srt"), .srt, "srt")
        h.expectEqual(SubtitleParser.detectFormat(fromFileName: "a/b/c.VTT"), .vtt, "vtt 大写")
        h.expectNil(SubtitleParser.detectFormat(fromFileName: "readme.md"), "md")
    }
    h.test("扩展名与内容不符时回退") {
        let ass = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,本文"
        let r = SubtitleParser.parse(ass, formatHint: .srt)
        h.expectEqual(r.cues.count, 1, "条目数")
        h.expectEqual(r.cues[0].text, "本文", "text")
    }
    h.test("自动解析 SRT") {
        let r = SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\n本文")
        h.expectEqual(r.format, .srt, "format")
        h.expectEqual(r.cues.count, 1, "条目数")
    }
    h.test("空输入") {
        let r = SubtitleParser.parse("")
        h.expect(r.cues.isEmpty, "应为空")
        h.expect(!r.warnings.isEmpty, "应有警告")
    }
}

// ── 其余测试套件 ──
runEditingSuites(h)
runStatsSuites(h)
runExportAlignSuites(h)
runMediaSuites(h)
runDatabaseSuites(h)
runPlaybackSuites(h)
runQueueSleepRevisionSuites(h)
runSubtitleSuites(h)
runSubtitleHistorySuites(h)
runClipSubtitleSuites(h)
runSubtitleSupportSuites(h)
runScriptSuites(h)
runTokenCueSuites(h)
runCrossLanguageSuites(h)
runScriptNoiseSuites(h)
runScriptSectionSuites(h)
runWaveformSuites(h)
runWhisperSuites(h)
runWorkAttachmentSuites(h)
runOrganizedMediaSuites(h)
runPlaylistOrderingSuites(h)
runReadingPositionSuites(h)
runBilingualSuites(h)
runScriptLayoutSuites(h)
runRelinkingSuites(h)
runDualLibrarySuites(h)
runZIPImportSuites(h)
runDirectLinkSuites(h)
runFormalVideoSuites(h)
runCallProfileSuites(h)

h.report()
