import Foundation
import HibikiCore

/// 媒体类型、自然排序、文件夹名解析 的测试套件
func runMediaSuites(_ h: Harness) {

    h.suite("媒体类型识别") {
        h.test("音频扩展名") {
            h.expectEqual(MediaExtensions.kind(forFileName: "track.mp3"), .audio, "mp3")
            h.expectEqual(MediaExtensions.kind(forFileName: "a.FLAC"), .audio, "大写 FLAC")
            h.expectEqual(MediaExtensions.kind(forFileName: "x.m4a"), .audio, "m4a")
            h.expectEqual(MediaExtensions.kind(forFileName: "摘选.CAF"), .audio, "CAF 可作为音轨重新导入")
            h.expectEqual(MediaExtensions.kind(forFileName: "x.ape"), .audio, "ape")
            h.expectEqual(MediaExtensions.kind(forFileName: "x.wv"), .audio, "wv")
        }
        h.test("视频扩展名") {
            h.expectEqual(MediaExtensions.kind(forFileName: "v.mkv"), .video, "mkv")
            h.expectEqual(MediaExtensions.kind(forFileName: "v.mp4"), .video, "mp4")
        }
        h.test("字幕/图片/文档/压缩包") {
            h.expectEqual(MediaExtensions.kind(forFileName: "s.srt"), .subtitle, "srt")
            h.expectEqual(MediaExtensions.kind(forFileName: "p.png"), .image, "png")
            h.expectEqual(MediaExtensions.kind(forFileName: "d.pdf"), .document, "pdf")
            h.expectEqual(MediaExtensions.kind(forFileName: "a.zip"), .archive, "zip")
        }
        h.test("未知类型") {
            h.expectEqual(MediaExtensions.kind(forFileName: "a.xyz"), .unknown, "xyz")
            h.expectEqual(MediaExtensions.kind(forFileName: "无扩展名"), .unknown, "无扩展名")
        }
        h.test("是否入库") {
            h.expect(MediaExtensions.isLibraryMedia("a.mp3"), "音频入库")
            h.expect(MediaExtensions.isLibraryMedia("a.mp4"), "视频入库")
            h.expect(!MediaExtensions.isLibraryMedia("a.pdf"), "文档不入库")
        }
        h.test("特典识别") {
            h.expect(MediaExtensions.isLikelyBonus("特典トラック.mp3"), "日文特典")
            h.expect(MediaExtensions.isLikelyBonus("bonus track.mp3"), "英文 bonus")
            h.expect(!MediaExtensions.isLikelyBonus("01. 本編.mp3"), "本篇不算特典")
        }
    }

    h.suite("自然排序") {
        h.test("数字按数值排") {
            let input = ["第10話.mp3", "第2話.mp3", "第1話.mp3"]
            h.expectEqual(NaturalSort.sorted(input), ["第1話.mp3", "第2話.mp3", "第10話.mp3"], "结果")
        }
        h.test("前导零") {
            h.expectEqual(NaturalSort.sorted(["02.mp3", "2.mp3"]), ["2.mp3", "02.mp3"], "前导零少的优先")
        }
        h.test("普通字符串比较") {
            h.expectEqual(NaturalSort.sorted(["b", "a", "c"]), ["a", "b", "c"], "字母序")
        }
        h.test("相同则稳定") {
            h.expectEqual(NaturalSort.compare("a", "a"), false, "相等返回 false")
        }
        h.test("track 序列") {
            let input = (1...12).map { "track\($0).mp3" }.shuffled()
            h.expectEqual(NaturalSort.sorted(input), (1...12).map { "track\($0).mp3" }, "乱序还原")
        }
    }

    h.suite("RJ 号提取") {
        h.test("商业作品 BJ 扫描和标题清理") {
            let item = FolderClassifier.classify(name: "[bj001234] 雨声日记")
            h.expectEqual(item.rjCode, "BJ001234", "保留编号原有位数")
            h.expectEqual(item.cleanedTitle, "雨声日记", "中括号中的编号")
            h.expectEqual(FolderNameParser.cleanTitle(from: "BJ001234 雨声日记"), "雨声日记", "裸编号")
        }
        h.test("标准 8 位") {
            h.expectEqual(FolderNameParser.rjCode(from: "RJ01234567 作品"), "RJ01234567", "结果")
        }
        h.test("小写") {
            h.expectEqual(FolderNameParser.rjCode(from: "rj12345678"), "RJ12345678", "结果")
        }
        h.test("方括号包裹") {
            h.expectEqual(FolderNameParser.rjCode(from: "[RJ01234567] 作品"), "RJ01234567", "结果")
        }
        h.test("带空格") {
            h.expectEqual(FolderNameParser.rjCode(from: "RJ 1234567"), "RJ01234567", "补齐到 8 位")
        }
        h.test("6 位补齐") {
            h.expectEqual(FolderNameParser.rjCode(from: "RJ123456"), "RJ00123456", "补齐")
        }
        h.test("没有则 nil") {
            h.expectNil(FolderNameParser.rjCode(from: "普通文件夹"), "结果")
        }
        h.test("不会误抓其他字母") {
            h.expectNil(FolderNameParser.rjCode(from: "ABC12345678"), "结果")
        }
    }

    h.suite("括号段落提取") {
        h.test("多段") {
            let r = FolderNameParser.bracketedSegments(from: "[社团] 作品名 [声优]")
            h.expectEqual(r, ["社团", "声优"], "结果")
        }
        h.test("中文括号") {
            let r = FolderNameParser.bracketedSegments(from: "（社团）作品（声优）")
            h.expectEqual(r, ["社团", "声优"], "结果")
        }
        h.test("无括号") {
            h.expectEqual(FolderNameParser.bracketedSegments(from: "作品名"), [], "结果")
        }
        h.test("嵌套") {
            let r = FolderNameParser.bracketedSegments(from: "[社团[内]] 名")
            h.expectEqual(r.count, 1, "只取最外层")
            h.expect(r[0].contains("内"), "内含内层内容")
        }
    }

    h.suite("标题清理") {
        h.test("去括号与 RJ") {
            let r = FolderNameParser.cleanTitle(from: "[社团] 素敵な作品 RJ01234567")
            h.expectEqual(r, "素敵な作品", "结果")
        }
        h.test("保留无 RJ 的正文") {
            let r = FolderNameParser.cleanTitle(from: "素敵な作品")
            h.expectEqual(r, "素敵な作品", "结果")
        }
        h.test("压缩多余空白") {
            let r = FolderNameParser.cleanTitle(from: "[A]  作品   [B]")
            h.expectEqual(r, "作品", "结果")
        }
        h.test("去首尾装饰符号") {
            let r = FolderNameParser.cleanTitle(from: "・作品・")
            h.expectEqual(r, "作品", "结果")
        }
    }

    h.suite("曲目名解析") {
        h.test("去轨号前缀") {
            h.expectEqual(FolderNameParser.trackTitle(from: "01. タイトル.mp3"), "タイトル", "点号")
            h.expectEqual(FolderNameParser.trackTitle(from: "02 - タイトル.mp3"), "タイトル", "横杠")
            h.expectEqual(FolderNameParser.trackTitle(from: "03) タイトル.mp3"), "タイトル", "右括号")
        }
        h.test("不加前缀的保持原样") {
            h.expectEqual(FolderNameParser.trackTitle(from: "タイトル.mp3"), "タイトル", "结果")
        }
        h.test("保留「第N話」这种正文") {
            h.expectEqual(FolderNameParser.trackTitle(from: "第3話「タイトル」.mp3"), "第3話「タイトル」", "结果")
        }
        h.test("提取轨号") {
            h.expectEqual(FolderNameParser.trackNumber(from: "01. x.mp3"), 1, "点号")
            h.expectEqual(FolderNameParser.trackNumber(from: "track12.mp3"), 12, "track")
            h.expectNil(FolderNameParser.trackNumber(from: "タイトル.mp3"), "无轨号")
        }
    }

    h.suite("自动分类") {
        h.test("启发式：两段括号") {
            let r = FolderClassifier.classify(name: "[社团名] 素敵な作品 [花子]")
            h.expectEqual(r.circle, ["社团名"], "社团")
            h.expectEqual(r.seiyuu, ["花子"], "声优")
            h.expectEqual(r.cleanedTitle, "素敵な作品", "标题")
        }
        h.test("启发式：一段括号当社团") {
            let r = FolderClassifier.classify(name: "[社团名] 作品")
            h.expectEqual(r.circle, ["社团名"], "社团")
            h.expectEqual(r.seiyuu, [], "无声优")
        }
        h.test("明确的社团与多人 CV 标签优先，语言说明不当作社团") {
            let parsed = FolderClassifier.classify(name: "【简体中文版】作品【CV：甲、乙】【社团：北风】")
            h.expectEqual(parsed.circle, ["北风"], "社团")
            h.expectEqual(parsed.seiyuu, ["甲", "乙"], "分开两位声优")
            let only = FolderClassifier.classify(name: "【繁體中文版】作品 CV: 乙")
            h.expectEqual(only.seiyuu, ["乙"], "末尾明确署名")
            h.expect(only.circle.isEmpty, "语言说明不算社团")
        }
        h.test("无括号不瞎猜") {
            let r = FolderClassifier.classify(name: "素敵な作品")
            h.expectEqual(r.circle, [], "社团空")
            h.expectEqual(r.cleanedTitle, "素敵な作品", "标题")
        }
        h.test("RJ 号独立提取") {
            let r = FolderClassifier.classify(name: "[社团] 作品 RJ01234567 [花子]")
            h.expectEqual(r.rjCode, "RJ01234567", "RJ")
            h.expectEqual(r.cleanedTitle, "作品", "标题不含 RJ")
        }
        h.test("规则优先于启发式") {
            let rules = [
                ClassificationRule(id: 1, pattern: "花子", dimension: "seiyuu", targetValue: "花子（别名）", priority: 10)
            ]
            let r = FolderClassifier.classify(name: "[社团] 作品 [花子]", rules: rules)
            h.expect(r.seiyuu.contains("花子（别名）"), "用了规则指定的值")
            h.expectEqual(r.matchedRuleIDs, [1], "命中记录")
        }
        h.test("正则规则") {
            let rules = [
                ClassificationRule(id: 2, pattern: "CV[:：]\\s*([^\\]]+)", dimension: "seiyuu", isRegex: true)
            ]
            let r = FolderClassifier.classify(name: "作品 CV: 太郎", rules: rules)
            h.expectEqual(r.seiyuu, ["太郎"], "捕获组取值")
        }
        h.test("useForStrip 从标题里删掉命中内容") {
            let rules = [
                ClassificationRule(id: 3, pattern: "【高音質】", dimension: "genre", useForStrip: true)
            ]
            let r = FolderClassifier.classify(name: "【高音質】素敵な作品", rules: rules)
            h.expectEqual(r.cleanedTitle, "素敵な作品", "标题已清理")
        }
        h.test("禁用规则不生效") {
            let rules = [
                ClassificationRule(id: 4, pattern: "x", dimension: "genre", enabled: false)
            ]
            let r = FolderClassifier.classify(name: "xyz", rules: rules)
            h.expect(r.tags["genre"] == nil, "未命中")
        }
    }
}
