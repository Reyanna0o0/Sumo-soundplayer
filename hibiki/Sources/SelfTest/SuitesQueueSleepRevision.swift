import Foundation
import HibikiCore

func runQueueSleepRevisionSuites(_ h: Harness) {
    func items(_ count: Int) -> [PlaybackQueueItem] {
        (0..<count).map { PlaybackQueueItem(workID: 7, trackID: Int64($0 + 1), workTitle: "队列测试",
            trackTitle: "音轨\($0 + 1)", filePath: "/fixture/\($0).wav", fileType: "wav") }
    }
    func ids(_ queue: PlaybackQueue) -> [Int64] { queue.order.map { queue.items[$0].trackID } }

    h.suite("队列拖动与12小时睡眠定时") {
        h.test("12小时上下限不溢出，倒计时覆盖完整43200秒") {
            let now = ContinuousClock.now
            h.expectEqual(PlaybackSleepTimer.minutesRange, 1...720, "分钟范围")
            for value in [Int.min, -1, 0, 721, Int.max] {
                h.expectNil(PlaybackSleepTimer.deadline(minutes: value, from: now), "拒绝非法\(value)")
            }
            h.expectEqual(PlaybackSleepTimer.deadline(minutes: 1, from: now)?.remainingSeconds(at: now), 60)
            let timer = PlaybackSleepTimer.deadline(minutes: 720, from: now)!
            h.expectEqual(timer.remainingSeconds(at: now), 43_200)
            h.expect(!timer.shouldStop(at: now.advanced(by: .seconds(43_199))), "最后一秒之前不停止")
            h.expect(timer.shouldStop(at: now.advanced(by: .seconds(43_200))), "第12小时结束时停止")
        }
        h.test("拖动后继项立即改变下一首，当前项身份不变") {
            var q = PlaybackQueue.make(items: items(4), startingAt: 1)
            q.repeatMode = .one
            let current = q.current
            h.expect(q.move(fromOffsets: [3], toOffset: 2), "第四首移到当前之后")
            h.expectEqual(ids(q), [1, 2, 4, 3])
            h.expectEqual(q.current, current, "不重建当前项")
            h.expectEqual(q.repeatMode, .one, "不改变循环偏好")
            _ = q.advance(auto: false)
            h.expectEqual(q.current?.trackID, 4, "下一首取手动顺序")
        }
        h.test("拖动当前项重定位游标，不跳到相邻项目") {
            var q = PlaybackQueue.make(items: items(5), startingAt: 1)
            let identity = q.current?.id
            _ = q.move(fromOffsets: [1], toOffset: 4)
            h.expectEqual(ids(q), [1, 3, 4, 2, 5])
            h.expectEqual(q.current?.id, identity)
            h.expectEqual(q.cursor, 3)
            _ = q.advance(auto: false)
            h.expectEqual(q.current?.trackID, 5)
        }
        h.test("多选移动、空移动和越界输入") {
            var q = PlaybackQueue.make(items: items(5), startingAt: 3)
            _ = q.move(fromOffsets: [0, 2], toOffset: 5)
            h.expectEqual(ids(q), [2, 4, 5, 1, 3])
            h.expectEqual(q.current?.trackID, 4)
            let before = q
            h.expect(!q.move(fromOffsets: [], toOffset: 0), "空移动")
            h.expect(!q.move(fromOffsets: [7], toOffset: 1), "越界来源")
            h.expect(!q.move(fromOffsets: [0], toOffset: -1), "负目标")
            h.expect(!q.move(fromOffsets: [0], toOffset: 6), "越界目标")
            h.expectEqual(q, before)
        }
        h.test("同一音频重复入队仍有独立出现身份") {
            let one = items(1)[0]
            var q = PlaybackQueue.make(items: [one, one, one], startingAt: 1)
            h.expectEqual(Set(q.items.map(\.id)).count, 3)
            h.expectEqual(q.items.map(\.trackID), [1, 1, 1])
            let current = q.current?.id
            let last = q.items[2].id
            let timer = PlaybackSleepTimer.endOfQueueItem(last)
            _ = q.move(fromOffsets: [0], toOffset: 3)
            h.expectEqual(q.current?.id, current)
            h.expectEqual(timer.retainingValidTarget(in: q), timer)
            h.expect(!timer.shouldStop(at: .now, finishedItemID: current), "同音频的另一出现不触发")
            h.expect(timer.shouldStop(at: .now, finishedItemID: last), "仅目标出现触发")
        }
        h.test("随机状态按当前可见顺序拖动") {
            var q = PlaybackQueue.make(items: items(6), startingAt: 2, shuffled: true, seed: 37)
            let current = q.current?.id
            let moved = q.items[q.order[4]].id
            _ = q.move(fromOffsets: [4], toOffset: 1)
            h.expect(q.isShuffled, "保留随机标记")
            h.expectEqual(q.current?.id, current)
            _ = q.advance()
            h.expectEqual(q.current?.id, moved)
        }
        h.test("删除其他曲目保留手动播放顺序") {
            var q = PlaybackQueue.make(items: items(5), startingAt: 1)
            _ = q.move(fromOffsets: [4], toOffset: 2)
            _ = q.remove(trackID: 1)
            h.expectEqual(ids(q), [2, 5, 3, 4])
            h.expectEqual(q.current?.trackID, 2)
            q.removeMedia([.track(3)])
            h.expectEqual(ids(q), [2, 5, 4])
            _ = q.advance()
            h.expectEqual(q.current?.trackID, 5)
        }
        h.test("前进到目标前的项目保留指定终点") {
            var q = PlaybackQueue.make(items: items(4))
            let target = q.items[3].id
            let timer = PlaybackSleepTimer.endOfQueueItem(target)
            _ = q.advance(auto: true)
            h.expectEqual(timer.retainingValidTarget(in: q), timer)
            h.expect(!timer.shouldStop(at: .now, finishedItemID: q.current?.id), "中间首不停止")
            h.expect(timer.shouldStop(at: .now, finishedItemID: target), "仅目标结束触发")
        }
        h.test("目标在后续队列内移动继续锚定同一个项目") {
            var q = PlaybackQueue.make(items: items(5), startingAt: 1)
            let timer = PlaybackSleepTimer.endOfQueueItem(q.items[4].id)
            _ = q.move(fromOffsets: [4], toOffset: 2)
            h.expectEqual(timer.retainingValidTarget(in: q), timer)
            h.expectEqual(q.upNext.first?.id, timer.queueTargetID)
        }
        h.test("目标移到当前之前与当前跨过目标都会取消") {
            var q = PlaybackQueue.make(items: items(5), startingAt: 1)
            let timer = PlaybackSleepTimer.endOfQueueItem(q.items[3].id)
            _ = q.move(fromOffsets: [3], toOffset: 0)
            h.expectEqual(timer.retainingValidTarget(in: q), .off)
            var second = PlaybackQueue.make(items: items(5), startingAt: 1)
            let another = PlaybackSleepTimer.endOfQueueItem(second.items[3].id)
            _ = second.move(fromOffsets: [1], toOffset: 5)
            h.expectEqual(another.retainingValidTarget(in: second), .off)
        }
        h.test("手动越过终点取消，向前面的未播完项目跳转仍有效") {
            var q = PlaybackQueue.make(items: items(5), startingAt: 1)
            let timer = PlaybackSleepTimer.endOfQueueItem(q.items[3].id)
            let prior = q.current?.id
            _ = q.jump(toItemIndex: 0)
            h.expectEqual(timer.afterManualSelection(from: prior, in: q), timer)
            _ = q.jump(toItemIndex: 4)
            h.expectEqual(timer.afterManualSelection(from: prior, in: q), .off)
        }
        h.test("离开目标并绕回队首取消，回到目标开头不取消") {
            var q = PlaybackQueue.make(items: items(3), startingAt: 2)
            q.repeatMode = .all
            let prior = q.current?.id
            let timer = PlaybackSleepTimer.endOfQueueItem(prior!)
            _ = q.retreat(elapsedMS: 9_000)
            h.expectEqual(timer.afterManualSelection(from: prior, in: q), timer)
            _ = q.advance(auto: false)
            h.expectEqual(timer.afterManualSelection(from: prior, in: q), .off)
        }
        h.test("删除目标清除，删除目标前面其他项不清除") {
            var q = PlaybackQueue.make(items: items(4))
            let timer = PlaybackSleepTimer.endOfQueueItem(q.items[3].id)
            q.removeTracks([2])
            h.expectEqual(timer.retainingValidTarget(in: q), timer)
            q.removeTracks([4])
            h.expectEqual(timer.retainingValidTarget(in: q), .off)
        }
        h.test("原本当前轨定时与分钟定时语义保持") {
            var q = PlaybackQueue.make(items: items(2))
            let track = PlaybackSleepTimer.endOfTrack(q.current!.id)
            let minutes = PlaybackSleepTimer.deadline(minutes: 720, from: .now)!
            _ = q.advance()
            h.expectEqual(track.retainingValidTarget(in: q), .off)
            h.expectEqual(minutes.retainingValidTarget(in: q), minutes)
            h.expectEqual(minutes.afterManualSelection(from: nil, in: q), minutes)
        }
    }
}
