import Foundation
import HibikiCore

/// 字幕查找 / 编辑 / 版本 的测试套件
func runEditingSuites(_ h: Harness) {

    func makeCues(_ specs: [(Int, Int, String)]) -> [SubtitleCue] {
        specs.enumerated().map { idx, s in
            SubtitleCue(index: idx, startMS: s.0, endMS: s.1, text: s.2)
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("SubtitleLocator 查找") {
        let cues = makeCues([
            (0, 1000, "一"),
            (1000, 3000, "二"),
            (3000, 5000, "三")
        ])
        let locator = SubtitleLocator(cues: cues)

        h.test("命中中间") {
            h.expectEqual(locator.index(at: 1500), 1, "index")
            h.expectEqual(locator.cue(at: 1500)?.text, "二", "text")
        }
        h.test("边界：起点属于自己") {
            h.expectEqual(locator.index(at: 1000), 1, "1000ms 属于第二句")
        }
        h.test("边界：终点不属于自己") {
            h.expectEqual(locator.index(at: 2999), 1, "2999ms 仍在第二句")
            h.expectEqual(locator.index(at: 5000), nil, "5000ms 已结束")
        }
        h.test("未开始") {
            h.expectEqual(locator.index(at: 0), 0, "0ms 在第一句（含起点）")
        }
        h.test("超出范围") {
            h.expectNil(locator.index(at: 99_999), "index")
        }
        h.test("空字幕") {
            let empty = SubtitleLocator(cues: [])
            h.expectNil(empty.index(at: 1000), "index")
            h.expectNil(empty.next(after: 1000), "next")
        }
        h.test("下一句") {
            h.expectEqual(locator.next(after: 1500)?.text, "三", "next")
            h.expectNil(locator.next(after: 4000), "最后一句之后没有下一句")
        }
        h.test("跳到下一句起点") {
            h.expectEqual(locator.nextStart(after: 1500), 3000, "nextStart")
            h.expectNil(locator.nextStart(after: 4000), "已无")
        }
        h.test("跳到上一句起点") {
            h.expectEqual(locator.previousStart(before: 4000), 3000, "previousStart")
        }
        h.test("重叠时返回多句") {
            let overlap = makeCues([(0, 5000, "甲"), (1000, 2000, "乙")])
            let l = SubtitleLocator(cues: overlap)
            let all = l.allIndices(at: 1500)
            h.expectEqual(all.count, 2, "应同时命中两句")
        }
        h.test("乱序输入自动排序") {
            let unsorted = makeCues([(3000, 4000, "后"), (0, 1000, "前")])
            let l = SubtitleLocator(cues: unsorted)
            h.expectEqual(l.cue(at: 500)?.text, "前", "排序后查找正确")
        }
        h.test("全屏阅读在片头、句间和片尾保持合适的定时句") {
            let lines = makeCues([(8000, 9000, "后"), (2000, 3500, "前")])
            let untimed = SubtitleCue(index: 2, startMS: 0, endMS: 0, text: "未打轴", status: .untimed)
            let locator = SubtitleLocator(cues: lines + [untimed])
            h.expectEqual(locator.readingCue(at: 0)?.id, lines[1].id, "片头预定位第一条定时句")
            h.expectEqual(locator.readingCue(at: 3500)?.id, lines[1].id, "句间保留刚结束的定时句")
            h.expectNil(locator.cue(at: 3500), "阅读定位不会产生正在播放的字幕")
            h.expectNil(locator.next(after: 3500), "保留原有下一句提示行为")
            h.expectEqual(locator.readingCue(at: 12000)?.id, lines[0].id, "片尾仍可读最后一句")
            h.expectNil(SubtitleLocator(cues: [untimed]).readingCue(at: 0), "纯文字保持手动阅读")
        }
        h.test("重叠时阅读跟随仍在播放的长句") {
            let lines = makeCues([(4000, 10000, "长句"), (5000, 6000, "短句")])
            let locator = SubtitleLocator(cues: lines)
            h.expectEqual(locator.readingCue(at: 5500)?.id, lines[1].id, "两句重叠时跟随当前句")
            h.expectEqual(locator.readingCue(at: 6200)?.id, lines[0].id, "短句结束时长句仍在播放")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("CueEditor 时间调整") {
        let cues = makeCues([(1000, 3000, "一"), (4000, 6000, "二")])

        h.test("只填开始后可定位；邻句移动或删除会重算自动句尾") {
            let unknown = SubtitleCue(index: 2, startMS: 0, endMS: 0, text: "无起点", status: .untimed)
            let input = [cues[1], cues[0], unknown] // 文字顺序与实际时间不同。
            let opened = CueEditor.settingEditableRange(input, at: 1, startMS: 1000, endMS: nil, durationMS: 9000)!
            h.expectEqual(opened[1].endMS, 4000, "下一条更晚的开始")
            h.expectEqual(opened[1].status, .provisional, "保存自动标志")
            h.expectEqual(SubtitleLocator(cues: opened).cue(at: 3500)?.text, "一", "可正常播放")
            let moved = CueEditor.settingEditableRange(opened, at: 0, startMS: 1500, endMS: 2500, durationMS: 9000)!
            let recalculated = CueEditor.resolvingAutomaticEnds(moved, durationMS: 9000)
            h.expectEqual(recalculated[1].endMS, 1500, "邻句缩短窗口")
            h.expectEqual(recalculated[0].endMS, 2500, "手动终点未变")
            h.expectEqual(recalculated[2], unknown, "无起点仍无时间")
            let deleted = CueEditor.delete(recalculated, at: [0])
            let extended = CueEditor.resolvingAutomaticEnds(deleted, durationMS: 9000)
            h.expectEqual(extended[0].endMS, 6000, "删除邻句后回到五秒")
            h.expectEqual(CueEditor.resolvingAutomaticEnds(extended, durationMS: 5500)[0].endMS, 5500, "不会越过音轨末尾")
            let fixed = CueEditor.settingEditableRange(extended, at: 0, startMS: 1000, endMS: 1300, durationMS: 9000)!
            h.expectEqual(CueEditor.resolvingAutomaticEnds(fixed, durationMS: 9000)[0].endMS, 1300, "手动句尾固定")
        }
        h.test("保留曲尾最后一毫秒并拒绝非法区间") {
            let auto = CueEditor.settingEditableRange(cues, at: 0, startMS: 8999, endMS: nil, durationMS: 9000)
            h.expectEqual(auto?.first?.endMS, 9000, "自动句尾精度")
            let manual = CueEditor.settingEditableRange(cues, at: 0, startMS: 8999, endMS: 9000, durationMS: 9000)
            h.expectEqual(manual?.first?.durationMS, 1, "手动毫秒不被强行拉长")
            h.expectNil(CueEditor.settingEditableRange(cues, at: 0, startMS: 9000, endMS: nil, durationMS: 9000), "曲尾不能再开始")
            h.expectNil(CueEditor.settingEditableRange(cues, at: 0, startMS: 8999, endMS: 9001, durationMS: 9000), "超过时长被拒绝")
            h.expectNil(CueEditor.settingEditableRange(cues, at: 0, startMS: 500, endMS: 500, durationMS: 9000), "结束不能等于开始")
            h.expectNil(CueEditor.settingEditableRange(cues, at: 0, startMS: -1, endMS: nil, durationMS: nil), "负数无效")
            h.expectEqual(CueEditor.automaticEndMS(in: cues, at: 0, startMS: 3999, durationMS: nil), 4000, "邻句仅相距1ms仍有效")
            h.expectEqual(CueEditor.automaticEndMS(in: cues, at: 0, startMS: 0, durationMS: 0), 4000, "预览排除自身原有的起点")
        }

        h.test("整体平移") {
            let shifted = CueEditor.shiftAll(cues, by: 500)
            h.expectEqual(shifted[0].startMS, 1500, "start")
            h.expectEqual(shifted[0].endMS, 3500, "end")
        }
        h.test("负数平移不越过 0") {
            let shifted = CueEditor.shiftAll(cues, by: -2000)
            h.expectEqual(shifted[0].startMS, 0, "start 钳到 0")
            h.expect(shifted[0].endMS > shifted[0].startMS, "时长仍为正")
        }
        h.test("只平移选中项") {
            let shifted = CueEditor.shift(cues, at: [1], by: 1000)
            h.expectEqual(shifted[0].startMS, 1000, "未选中不变")
            h.expectEqual(shifted[1].startMS, 5000, "选中项已移动")
        }
        h.test("设置开始时间（打轴）") {
            let r = CueEditor.settingStart(cues, at: 0, to: 2000)
            h.expectEqual(r[0].startMS, 2000, "start")
        }
        h.test("开始时间不能越过结束时间") {
            let r = CueEditor.settingStart(cues, at: 0, to: 9999)
            h.expect(r[0].startMS < r[0].endMS, "start 必须小于 end")
            h.expectEqual(r[0].durationMS, CueEditor.minimumDurationMS, "被压到最小时长")
        }
        h.test("设置结束时间") {
            let r = CueEditor.settingEnd(cues, at: 0, to: 2500)
            h.expectEqual(r[0].endMS, 2500, "end")
        }
        h.test("结束时间不能早于开始") {
            let r = CueEditor.settingEnd(cues, at: 1, to: 0)
            h.expectEqual(r[1].endMS, r[1].startMS + CueEditor.minimumDurationMS, "被抬到最小时长")
        }
        h.test("贴合下一句开始") {
            let gapped = makeCues([(0, 1000, "一"), (5000, 6000, "二")])
            let r = CueEditor.snapEndsToNextStart(gapped, gapMS: 40)
            h.expectEqual(r[0].endMS, 4960, "结束时间贴到下一句前 40ms")
        }
        h.test("越界下标安全") {
            h.expectEqual(CueEditor.settingStart(cues, at: 99, to: 1).count, cues.count, "长度不变")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("CueEditor 结构操作") {
        let cues = makeCues([(1000, 5000, "あ、そこはだめよ")])

        h.test("拆分：时间中点") {
            let r = CueEditor.split(cues, at: 0)
            h.expectEqual(r.count, 2, "条目数")
            h.expectEqual(r[0].endMS, 3000, "前半结束于中点")
            h.expectEqual(r[1].startMS, 3000, "后半从中间开始")
            h.expectEqual(r[0].startMS, 1000, "前半起点不变")
            h.expectEqual(r[1].endMS, 5000, "后半终点不变")
        }
        h.test("拆分：按标点选切点") {
            let r = CueEditor.split(cues, at: 0)
            h.expect(!r[0].text.isEmpty && !r[1].text.isEmpty, "两半都有文字")
            h.expectEqual(r[0].text + r[1].text, "あ、そこはだめよ", "文字不丢失（无空格语言）")
        }
        h.test("拆分：指定时间") {
            let r = CueEditor.split(cues, at: 0, offsetMS: 1000)
            h.expectEqual(r[0].endMS, 2000, "按指定偏移切")
        }
        h.test("拆分：下标重排") {
            let r = CueEditor.split(cues, at: 0)
            h.expectEqual(r.map(\.index), [0, 1], "index")
        }
        h.test("拆分：双语保留") {
            var withT = cues
            withT[0].translatedText = "Ah, not there"
            let r = CueEditor.split(withT, at: 0)
            h.expectNotNil(r[0].translatedText, "前半有译文")
            h.expectNotNil(r[1].translatedText, "后半有译文")
        }

        h.test("合并") {
            let two = makeCues([(1000, 2000, "上"), (2000, 3000, "下")])
            let r = CueEditor.merge(two, at: 0)
            h.expectEqual(r.count, 1, "条目数")
            h.expectEqual(r[0].startMS, 1000, "start")
            h.expectEqual(r[0].endMS, 3000, "end")
            h.expectEqual(r[0].text, "上\n下", "text")
        }
        h.test("合并最后一条无效") {
            let two = makeCues([(1000, 2000, "上")])
            h.expectEqual(CueEditor.merge(two, at: 0).count, 1, "长度不变")
        }
        h.test("合并时译文也合并") {
            var two = makeCues([(1000, 2000, "上"), (2000, 3000, "下")])
            two[0].translatedText = "up"
            two[1].translatedText = "down"
            let r = CueEditor.merge(two, at: 0)
            h.expectEqual(r[0].translatedText, "up\ndown", "译文合并")
        }

        h.test("插入空句") {
            let r = CueEditor.insertEmpty(cues, after: 0)
            h.expectEqual(r.count, 2, "条目数")
            h.expectEqual(r[1].text, "", "空句")
            h.expect(r[1].startMS >= r[0].startMS, "时间合理")
        }
        h.test("删除") {
            let three = makeCues([(0, 1, "a"), (2, 3, "b"), (4, 5, "c")])
            let r = CueEditor.delete(three, at: [1])
            h.expectEqual(r.count, 2, "条目数")
            h.expectEqual(r.map(\.text), ["a", "c"], "剩下的内容")
            h.expectEqual(r.map(\.index), [0, 1], "index 重排")
        }
        h.test("删除多余的空句") {
            let mixed = makeCues([(0, 1, "a"), (2, 3, "  "), (4, 5, "c")])
            h.expectEqual(CueEditor.removingEmpty(mixed).count, 2, "条目数")
        }
        h.test("排序") {
            let unsorted = makeCues([(3000, 4000, "后"), (0, 1000, "前")])
            let r = CueEditor.sorted(unsorted)
            h.expectEqual(r.map(\.text), ["前", "后"], "顺序")
            h.expectEqual(r.map(\.index), [0, 1], "index")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("CueEditor 文本") {
        let cues = makeCues([(0, 1000, "本文")])
        h.test("改文字不会确认未知的时间") {
            var marked = cues
            marked[0].status = .unaligned
            let r = CueEditor.settingText(marked, at: 0, to: "修正後")
            h.expectEqual(r[0].text, "修正後", "text")
            h.expectEqual(r[0].status, .unaligned, "文字修正不等于时间已确认")
        }
        h.test("设置译文") {
            let r = CueEditor.settingTranslation(cues, at: 0, to: " 译文 ")
            h.expectEqual(r[0].translatedText, "译文", "trim")
        }
        h.test("清空译文") {
            var withT = cues
            withT[0].translatedText = "x"
            let r = CueEditor.settingTranslation(withT, at: 0, to: "   ")
            h.expectNil(r[0].translatedText, "空白视为清空")
        }
        h.test("设置说话人") {
            let r = CueEditor.settingSpeaker(cues, at: 0, to: "太郎")
            h.expectEqual(r[0].speaker, "太郎", "speaker")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("CueDiffer 版本对比") {
        h.test("无改动") {
            let cues = makeCues([(0, 1000, "a"), (1000, 2000, "b")])
            h.expect(CueDiffer.diff(cues, cues).isEmpty, "应无差异")
        }
        h.test("改文字") {
            var after = makeCues([(0, 1000, "a"), (1000, 2000, "b")])
            let before = after
            after[0].text = "A"
            let d = CueDiffer.diff(before, after)
            h.expectEqual(d.count, 1, "差异数")
            h.expectEqual(d[0].kind, .modified, "kind")
            h.expect(d[0].fields.contains(.text), "应标记 text 变化")
        }
        h.test("改时间") {
            var after = makeCues([(0, 1000, "a")])
            let before = after
            after[0].startMS = 500
            let d = CueDiffer.diff(before, after)
            h.expect(d[0].fields.contains(.start), "应标记 start 变化")
        }
        h.test("新增句") {
            let before = makeCues([(0, 1000, "a")])
            let after = makeCues([(0, 1000, "a"), (1000, 2000, "b")])
            let d = CueDiffer.diff(before, after)
            h.expectEqual(d.filter { $0.kind == .added }.count, 1, "新增 1 条")
        }
        h.test("删除句") {
            let before = makeCues([(0, 1000, "a"), (1000, 2000, "b")])
            let after = makeCues([(0, 1000, "a")])
            let d = CueDiffer.diff(before, after)
            h.expectEqual(d.filter { $0.kind == .removed }.count, 1, "删除 1 条")
        }
        h.test("UUID 全不同时退化为按位置比较") {
            let before = [SubtitleCue(index: 0, startMS: 0, endMS: 1000, text: "a")]
            let after = [SubtitleCue(index: 0, startMS: 0, endMS: 1000, text: "b")]
            let d = CueDiffer.diff(before, after)
            h.expectEqual(d.count, 1, "差异数")
            h.expectEqual(d[0].kind, .modified, "kind")
        }
        h.test("描述文字") {
            var after = makeCues([(0, 1000, "a")])
            let before = after
            after[0].text = "A"
            let d = CueDiffer.diff(before, after)
            h.expect(CueDiffer.describe(d[0]).contains("text"), "描述含字段名")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("UndoStack 撤销") {
        h.test("记录与撤销") {
            let stack = UndoStack<Int>(capacity: 10)
            stack.record(1)
            stack.record(2)
            h.expect(stack.canUndo, "可撤销")
            h.expectEqual(stack.undo(current: 3), 2, "撤销一步")
            h.expectEqual(stack.undo(current: 2), 1, "再撤销")
            h.expectNil(stack.undo(current: 1), "已到底")
        }
        h.test("重做") {
            let stack = UndoStack<Int>(capacity: 10)
            stack.record(1)
            _ = stack.undo(current: 2)
            h.expect(stack.canRedo, "可重做")
            h.expectEqual(stack.redo(current: 1), 2, "重做一步")
        }
        h.test("新改动清空重做") {
            let stack = UndoStack<Int>(capacity: 10)
            stack.record(1)
            _ = stack.undo(current: 2)
            stack.record(9)
            h.expect(!stack.canRedo, "重做栈已清空")
        }
        h.test("容量上限") {
            let stack = UndoStack<Int>(capacity: 3)
            for i in 1...10 { stack.record(i) }
            h.expectEqual(stack.undoCount, 3, "只保留最近 3 步")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("SubtitleEditingSession 编辑会话") {
        h.test("改动后标记脏") {
            let session = SubtitleEditingSession(cues: makeCues([(0, 1000, "a")]))
            h.expect(!session.isDirty, "初始干净")
            session.apply { CueEditor.settingText($0, at: 0, to: "b") }
            h.expect(session.isDirty, "改动后变脏")
            h.expectEqual(session.cues[0].text, "b", "内容已变")
        }
        h.test("无变化不记录撤销点") {
            let session = SubtitleEditingSession(cues: makeCues([(0, 1000, "a")]))
            session.apply { $0 }   // 原样返回
            h.expect(!session.canUndo, "不该有撤销点")
            h.expect(!session.isDirty, "不该变脏")
        }
        h.test("撤销与重做") {
            let session = SubtitleEditingSession(cues: makeCues([(0, 1000, "a")]))
            session.apply { CueEditor.settingText($0, at: 0, to: "b") }
            h.expect(session.undo(), "撤销成功")
            h.expectEqual(session.cues[0].text, "a", "已还原")
            h.expect(session.redo(), "重做成功")
            h.expectEqual(session.cues[0].text, "b", "已重做")
        }
        h.test("与基线对比") {
            let session = SubtitleEditingSession(cues: makeCues([(0, 1000, "a")]))
            session.apply { CueEditor.settingText($0, at: 0, to: "b") }
            session.apply { CueEditor.settingText($0, at: 0, to: "c") }
            h.expectEqual(session.changeCountFromBaseline(), 1, "两条改动合并成 1 处差异")
            h.expect(session.suggestedVersionNote().contains("1"), "备注含数量")
        }
        h.test("提交为基线后变干净") {
            let session = SubtitleEditingSession(cues: makeCues([(0, 1000, "a")]))
            session.apply { CueEditor.settingText($0, at: 0, to: "b") }
            session.commitAsBaseline()
            h.expect(!session.isDirty, "变干净")
            h.expectEqual(session.changeCountFromBaseline(), 0, "无差异")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("SubtitleVersionStore 版本管理") {
        h.test("初始有基线版本") {
            let store = SubtitleVersionStore(initialCues: makeCues([(0, 1000, "a")]))
            h.expectEqual(store.versions.count, 1, "版本数")
            h.expect(store.activeVersion.isBaseline, "基线标记")
            h.expectEqual(store.activeVersion.number, 1, "版本号")
        }
        h.test("新建版本号递增") {
            let store = SubtitleVersionStore(initialCues: makeCues([(0, 1000, "a")]))
            let v2 = store.createVersion(from: makeCues([(0, 1000, "b")]), note: "改文字")
            h.expectEqual(v2.number, 2, "版本号")
            h.expectEqual(store.activeVersion.id, v2.id, "自动切换到新版本")
            h.expectEqual(v2.note, "改文字", "备注")
        }
        h.test("切换版本") {
            let store = SubtitleVersionStore(initialCues: makeCues([(0, 1000, "a")]))
            let v1 = store.activeVersion.id
            _ = store.createVersion(from: makeCues([(0, 1000, "b")]), note: "")
            h.expect(store.switchTo(v1), "切换成功")
            h.expectEqual(store.activeVersion.cues[0].text, "a", "回到第一版内容")
        }
        h.test("基线不能删") {
            let store = SubtitleVersionStore(initialCues: makeCues([(0, 1000, "a")]))
            let baselineID = store.activeVersion.id
            h.expect(!store.delete(baselineID), "应拒绝删除基线")
        }
        h.test("删除普通版本") {
            let store = SubtitleVersionStore(initialCues: makeCues([(0, 1000, "a")]))
            let v2 = store.createVersion(from: makeCues([(0, 1000, "b")]), note: "")
            h.expect(store.delete(v2.id), "删除成功")
            h.expectEqual(store.versions.count, 1, "版本数")
        }
        h.test("裁剪保留基线") {
            let store = SubtitleVersionStore(initialCues: makeCues([(0, 1000, "a")]))
            for i in 2...10 {
                _ = store.createVersion(from: makeCues([(0, 1000, "v\(i)")]), note: "")
            }
            store.prune(keepingLast: 3)
            h.expectEqual(store.versions.count, 4, "1 基线 + 3 最新")
            h.expect(store.versions.contains(where: \.isBaseline), "基线仍在")
            h.expect(store.versions.contains { $0.note == "" && $0.number == 10 }, "最新的保留")
        }
        h.test("两版对比") {
            let store = SubtitleVersionStore(initialCues: makeCues([(0, 1000, "a")]))
            let v1 = store.activeVersion.id
            var changed = makeCues([(0, 1000, "a")])
            changed[0].text = "b"
            let v2 = store.createVersion(from: changed, note: "")
            let d = store.comparison(from: v1, to: v2.id)
            h.expectEqual(d.count, 1, "差异数")
        }
        h.test("版本摘要") {
            let v = SubtitleVersion(number: 3, note: "修正 5 处", cues: [])
            h.expect(v.summary.contains("v3"), "含版本号")
            h.expect(v.summary.contains("修正 5 处"), "含备注")
        }
    }
}
