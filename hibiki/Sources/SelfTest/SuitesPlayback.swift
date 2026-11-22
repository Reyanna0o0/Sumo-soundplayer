import Foundation
import HibikiCore

/// 播放引擎纯逻辑部分的测试套件
func runPlaybackSuites(_ h: Harness) {

    func makeItems(_ count: Int) -> [PlaybackQueueItem] {
        (0..<count).map { index in
            PlaybackQueueItem(
                workID: 1,
                trackID: Int64(index + 1),
                workTitle: "作品",
                trackTitle: "曲\(index + 1)",
                filePath: "/audio/\(index + 1).wav",
                fileType: "wav"
            )
        }
    }

    h.suite("睡眠定时") {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(60))
        let first = UUID(), next = UUID()
        h.test("分钟倒计时使用现实时间并忽略曲目切换") {
            let timer = PlaybackSleepTimer.deadline(deadline)
            h.expectEqual(timer.remainingSeconds(at: start), 60, "一分钟完整")
            h.expectEqual(timer.remainingSeconds(at: deadline.advanced(by: .milliseconds(-1))), 1, "显示向上取整")
            h.expect(!timer.shouldStop(at: start, finishedItemID: first), "到期前可换曲")
            h.expect(timer.shouldStop(at: deadline), "到期即停")
            h.expect(timer.shouldStop(at: deadline.advanced(by: .seconds(10)), finishedItemID: next), "中断回来已过期")
        }
        h.test("本轨结束按队列条目标识，关闭后不再拦截") {
            let timer = PlaybackSleepTimer.endOfTrack(first)
            h.expect(!timer.shouldStop(at: deadline), "听完整轨不受时间影响")
            h.expect(!timer.shouldStop(at: deadline, finishedItemID: next), "过时的其它回调无效")
            h.expect(timer.shouldStop(at: start, finishedItemID: first), "目标播完即停")
            h.expect(!PlaybackSleepTimer.off.shouldStop(at: deadline, finishedItemID: first), "取消后正常连播")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("音频数学") {
        h.test("速度夹紧") {
            h.expectEqual(AudioMath.clampRate(0.1), 0.5, "下限")
            h.expectEqual(AudioMath.clampRate(10), 4.0, "上限")
            h.expectEqual(AudioMath.clampRate(1.25), 1.25, "区间内不变")
        }
        h.test("432Hz 调音音分") {
            let cents = AudioMath.cents432
            // 432/440 = 降约 31.77 音分
            h.expect(abs(cents + 31.77) < 0.1, "应约 −31.77 音分，实际 \(cents)")
        }
        h.test("440Hz 零偏移") {
            h.expect(abs(AudioMath.centsFromStandardTuning(a4: 440)) < 0.001, "440 应为 0")
        }
        h.test("半音换算") {
            h.expectEqual(AudioMath.cents(fromSemitones: 1), 100, "1 半音 = 100 音分")
            h.expectEqual(AudioMath.cents(fromSemitones: -2), -200, "负半音")
        }
        h.test("音调夹紧") {
            h.expectEqual(AudioMath.clampSemitones(20), 12, "上限")
            h.expectEqual(AudioMath.clampSemitones(-20), -12, "下限")
        }
        h.test("自然速度区间") {
            h.expect(AudioMath.isRateNatural(1.0), "1.0 自然")
            h.expect(AudioMath.isRateNatural(1.5), "1.5 自然")
            h.expect(!AudioMath.isRateNatural(3.0), "3.0 超出")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("淡入淡出") {
        h.test("线性曲线端点") {
            h.expectEqual(FadeEnvelope.gain(progress: 0, curve: .linear), 0, "起点")
            h.expectEqual(FadeEnvelope.gain(progress: 1, curve: .linear), 1, "终点")
            h.expectEqual(FadeEnvelope.gain(progress: 0.5, curve: .linear), 0.5, "中点")
        }
        h.test("等功率曲线起点终点") {
            h.expect(abs(FadeEnvelope.gain(progress: 0, curve: .equalPower)) < 0.001, "起点 0")
            h.expect(abs(FadeEnvelope.gain(progress: 1, curve: .equalPower) - 1) < 0.001, "终点 1")
        }
        h.test("等功率中点更高") {
            // sin(π/4) ≈ 0.707，比线性的 0.5 高，听感上更均匀
            let mid = FadeEnvelope.gain(progress: 0.5, curve: .equalPower)
            h.expect(abs(mid - 0.707) < 0.01, "中点应约 0.707，实际 \(mid)")
        }
        h.test("单调递增") {
            var previous: Float = -1
            for step in 0...10 {
                let gain = FadeEnvelope.gain(progress: Double(step) / 10, curve: .equalPower)
                h.expect(gain >= previous, "第 \(step) 步不应下降")
                previous = gain
            }
        }
        h.test("按时间计算") {
            h.expectEqual(FadeEnvelope.gain(elapsed: 0, duration: 1), 0, "起点")
            h.expectEqual(FadeEnvelope.gain(elapsed: 2, duration: 1), 1, "超时后满音量")
            h.expectEqual(FadeEnvelope.gain(elapsed: 1, duration: 0), 1, "零时长直接满音量")
        }
        h.test("淡出") {
            h.expectEqual(FadeEnvelope.fadeOutGain(elapsed: 0, duration: 1, curve: .linear), 1, "刚开始")
            h.expectEqual(FadeEnvelope.fadeOutGain(elapsed: 1, duration: 1, curve: .linear), 0, "结束为 0")
        }
        h.test("进度越界被夹紧") {
            h.expectEqual(FadeEnvelope.gain(progress: -5), 0, "负数")
            h.expectEqual(FadeEnvelope.gain(progress: 5), 1, "超 1")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("续播策略") {
        h.test("太短不记续播") {
            h.expect(!ResumePolicy.shouldSavePosition(positionMS: 3_000, durationMS: 600_000), "3 秒不记")
        }
        h.test("正常位置要记") {
            h.expect(ResumePolicy.shouldSavePosition(positionMS: 60_000, durationMS: 600_000), "1 分钟要记")
        }
        h.test("接近结尾不记") {
            h.expect(!ResumePolicy.shouldSavePosition(positionMS: 595_000, durationMS: 600_000), "最后 5 秒不记")
        }
        h.test("时长未知时按位置判断") {
            h.expect(ResumePolicy.shouldSavePosition(positionMS: 60_000, durationMS: nil), "够长就记")
            h.expectNil(nil as Bool?, "占位")
        }
        h.test("恢复位置") {
            h.expectEqual(ResumePolicy.resumePosition(savedMS: 60_000, durationMS: 600_000), 60_000, "正常恢复")
            h.expectEqual(ResumePolicy.resumePosition(savedMS: 595_000, durationMS: 600_000), 0, "接近结尾则从头")
            h.expectEqual(ResumePolicy.resumePosition(savedMS: 1_000, durationMS: 600_000), 0, "太短则从头")
        }
        h.test("听完判定 90%") {
            h.expect(ResumePolicy.shouldMarkListened(positionMS: 900_000, durationMS: 1_000_000), "90% 算听完")
            h.expect(!ResumePolicy.shouldMarkListened(positionMS: 800_000, durationMS: 1_000_000), "80% 不算")
            h.expect(!ResumePolicy.shouldMarkListened(positionMS: 900_000, durationMS: nil), "时长未知不算")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("播放时钟") {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        h.test("暂停时位置不变") {
            var clock = PlaybackClock(positionMS: 5_000)
            h.expectEqual(clock.position(at: t0.addingTimeInterval(10)), 5_000, "暂停不动")
        }
        h.test("播放按速率推进") {
            var clock = PlaybackClock(positionMS: 0, rate: 1.0)
            clock.play(at: t0)
            h.expectEqual(clock.position(at: t0.addingTimeInterval(2)), 2_000, "2 秒 = 2000ms")
        }
        h.test("倍速推进") {
            var clock = PlaybackClock(positionMS: 0, rate: 2.0)
            clock.play(at: t0)
            h.expectEqual(clock.position(at: t0.addingTimeInterval(2)), 4_000, "2 倍速 = 4000ms")
        }
        h.test("暂停保留位置") {
            var clock = PlaybackClock(positionMS: 0)
            clock.play(at: t0)
            clock.pause(at: t0.addingTimeInterval(3))
            h.expectEqual(clock.position(at: t0.addingTimeInterval(100)), 3_000, "暂停后停在 3000ms")
        }
        h.test("跳转") {
            var clock = PlaybackClock(positionMS: 0)
            clock.play(at: t0)
            clock.seek(to: 10_000, at: t0.addingTimeInterval(1))
            h.expectEqual(clock.position(at: t0.addingTimeInterval(2)), 11_000, "跳转后继续推进")
        }
        h.test("改速率保持连续") {
            var clock = PlaybackClock(positionMS: 0, rate: 1.0)
            clock.play(at: t0)
            clock.setRate(2.0, at: t0.addingTimeInterval(1))
            // 1 秒按 1 倍 = 1000ms，之后 1 秒按 2 倍 = 2000ms
            h.expectEqual(clock.position(at: t0.addingTimeInterval(2)), 3_000, "位置连续")
        }
        h.test("被时长夹紧") {
            var clock = PlaybackClock(positionMS: 0, rate: 1.0, durationMS: 5_000)
            clock.play(at: t0)
            h.expectEqual(clock.position(at: t0.addingTimeInterval(10)), 5_000, "不超过总时长")
        }
        h.test("进度百分比") {
            var clock = PlaybackClock(positionMS: 0, durationMS: 10_000)
            clock.play(at: t0)
            h.expect(abs(clock.progress(at: t0.addingTimeInterval(5)) - 0.5) < 0.01, "50%")
        }
        h.test("用引擎位置校准") {
            var clock = PlaybackClock(positionMS: 0)
            clock.play(at: t0)
            // 时钟认为 10 秒，引擎说 10.5 秒，差 500ms 超过容差 → 校正
            let corrected = clock.reconcile(enginePositionMS: 10_500, at: t0.addingTimeInterval(10))
            h.expect(corrected, "应校正")
            h.expectEqual(clock.position(at: t0.addingTimeInterval(10)), 10_500, "已校正")
        }
        h.test("小幅漂移不校正") {
            var clock = PlaybackClock(positionMS: 0)
            clock.play(at: t0)
            let corrected = clock.reconcile(enginePositionMS: 10_050, at: t0.addingTimeInterval(10))
            h.expect(!corrected, "100ms 漂移不校正，避免界面抖动")
        }
        h.test("换曲重置") {
            var clock = PlaybackClock(positionMS: 50_000, isRunning: true)
            clock.play(at: t0)
            clock.reset(positionMS: 0, durationMS: 300_000, at: t0)
            h.expectEqual(clock.position(at: t0), 0, "归零")
            h.expectEqual(clock.durationMS, 300_000, "新时长")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("播放队列") {
        h.test("基本推进") {
            var queue = PlaybackQueue.make(items: makeItems(3))
            h.expectEqual(queue.current?.trackTitle, "曲1", "初始第一首")
            h.expect(queue.advance(), "能前进")
            h.expectEqual(queue.current?.trackTitle, "曲2", "第二首")
            h.expect(queue.advance(), "能前进")
            h.expectEqual(queue.current?.trackTitle, "曲3", "第三首")
        }
        h.test("不重复时到末尾停止") {
            var queue = PlaybackQueue.make(items: makeItems(2))
            _ = queue.advance()
            h.expect(!queue.advance(), "末尾不前进")
            h.expectEqual(queue.current?.trackTitle, "曲2", "停在最后一首")
        }
        h.test("列表循环回到开头") {
            var queue = PlaybackQueue.make(items: makeItems(2))
            queue.repeatMode = .all
            _ = queue.advance()
            h.expect(queue.advance(), "能回到开头")
            h.expectEqual(queue.current?.trackTitle, "曲1", "第一首")
        }
        h.test("单曲循环：自动时原地重播") {
            var queue = PlaybackQueue.make(items: makeItems(3))
            queue.repeatMode = .one
            h.expect(queue.advance(auto: true), "自动前进为真")
            h.expectEqual(queue.current?.trackTitle, "曲1", "还在第一首")
        }
        h.test("单曲循环：手动时换曲") {
            var queue = PlaybackQueue.make(items: makeItems(3))
            queue.repeatMode = .one
            _ = queue.advance(auto: false)
            h.expectEqual(queue.current?.trackTitle, "曲2", "手动仍换曲")
        }
        h.test("上一首") {
            var queue = PlaybackQueue.make(items: makeItems(3), startingAt: 1)
            h.expect(queue.retreat(elapsedMS: 0), "能后退")
            h.expectEqual(queue.current?.trackTitle, "曲1", "第一首")
        }
        h.test("播放超过 3 秒时上一首应回到本曲开头") {
            var queue = PlaybackQueue.make(items: makeItems(3), startingAt: 2)
            let handled = queue.retreat(elapsedMS: 5_000)
            h.expect(handled, "应被处理")
            h.expectEqual(queue.current?.trackTitle, "曲3", "不换曲（调用方负责归零）")
        }
        h.test("第一首再上一首：列表循环到末尾") {
            var queue = PlaybackQueue.make(items: makeItems(3))
            queue.repeatMode = .all
            h.expect(queue.retreat(elapsedMS: 0), "能循环")
            h.expectEqual(queue.current?.trackTitle, "曲3", "跳到最后一首")
        }
        h.test("跳转到指定曲目") {
            var queue = PlaybackQueue.make(items: makeItems(5))
            h.expect(queue.jump(toItemIndex: 3), "跳转成功")
            h.expectEqual(queue.current?.trackTitle, "曲4", "第 4 首")
            h.expect(!queue.jump(toItemIndex: 99), "越界失败")
        }
        h.test("下一首预览") {
            let queue = PlaybackQueue.make(items: makeItems(4), startingAt: 1)
            h.expectEqual(queue.upNext.map(\.trackTitle), ["曲3", "曲4"], "接下来的两首")
        }
        h.test("随机播放：同一 seed 顺序可复现") {
            let items = makeItems(10)
            var a = PlaybackQueue.make(items: items, shuffled: true, seed: 42)
            var b = PlaybackQueue.make(items: items, shuffled: true, seed: 42)
            var orderA: [String] = []
            var orderB: [String] = []
            for _ in 0..<10 {
                orderA.append(a.current?.trackTitle ?? "")
                orderB.append(b.current?.trackTitle ?? "")
                _ = a.advance()
                _ = b.advance()
            }
            h.expectEqual(orderA, orderB, "同 seed 顺序一致")
        }
        h.test("随机播放覆盖全部曲目") {
            var queue = PlaybackQueue.make(items: makeItems(10), shuffled: true, seed: 7)
            var seen = Set<String>()
            for _ in 0..<10 {
                if let title = queue.current?.trackTitle { seen.insert(title) }
                _ = queue.advance()
            }
            h.expectEqual(seen.count, 10, "十首都播到")
        }
        h.test("随机模式下当前曲目仍在首位") {
            let queue = PlaybackQueue.make(items: makeItems(5), startingAt: 2, shuffled: true, seed: 3)
            h.expectEqual(queue.current?.trackTitle, "曲3", "从指定曲目开始")
        }
        h.test("关闭随机恢复原始顺序") {
            var queue = PlaybackQueue.make(items: makeItems(5), startingAt: 2, shuffled: true, seed: 3)
            queue.setShuffle(false)
            h.expectEqual(queue.current?.trackTitle, "曲3", "当前曲目不变")
            _ = queue.advance()
            h.expectEqual(queue.current?.trackTitle, "曲4", "按原始顺序前进")
        }
        h.test("移除当前曲目") {
            var queue = PlaybackQueue.make(items: makeItems(3), startingAt: 1)
            h.expect(queue.remove(trackID: 2), "移除成功")
            h.expectEqual(queue.items.count, 2, "剩两首")
            h.expectEqual(queue.current?.trackTitle, "曲3", "顺延到下一首")
        }
        h.test("移除前面的曲目不影响当前") {
            var queue = PlaybackQueue.make(items: makeItems(3), startingAt: 2)
            _ = queue.remove(trackID: 1)
            h.expectEqual(queue.current?.trackTitle, "曲3", "仍是第三首")
        }
        h.test("整体替换保留正在播的曲目") {
            var queue = PlaybackQueue.make(items: makeItems(3), startingAt: 1)
            queue.replaceItems(makeItems(6))
            h.expectEqual(queue.current?.trackTitle, "曲2", "还在同一首")
        }
        h.test("空队列安全") {
            var queue = PlaybackQueue(items: [])
            h.expectNil(queue.current, "无当前曲目")
            h.expect(!queue.advance(), "不能前进")
            h.expect(!queue.retreat(), "不能后退")
            h.expect(queue.upNext.isEmpty, "无后续")
        }
        h.test("进度描述") {
            let queue = PlaybackQueue.make(items: makeItems(3), startingAt: 1)
            h.expectEqual(queue.progressDescription, "2/3", "2/3")
        }
        h.test("重复模式循环切换") {
            h.expectEqual(RepeatMode.off.next, .all, "关→列表")
            h.expectEqual(RepeatMode.all.next, .one, "列表→单曲")
            h.expectEqual(RepeatMode.one.next, .off, "单曲→关")
        }
    }
}
