import Foundation
import AVFoundation
import HibikiCore

/// 波形与时间轴换算
func runWaveformSuites(_ h: Harness) {

    // ─────────────────────────────────────────────────────────
    h.suite("波形时间轴换算") {
        let timeline = WaveformTimeline(durationMS: 100_000, peaks: Array(repeating: 0.5, count: 100))

        h.test("时间转比例") {
            h.expectEqual(timeline.progress(forTimeMS: 0), 0.0, "起点")
            h.expectEqual(timeline.progress(forTimeMS: 50_000), 0.5, "中点")
            h.expectEqual(timeline.progress(forTimeMS: 100_000), 1.0, "终点")
        }

        h.test("比例转时间") {
            h.expectEqual(timeline.timeMS(forProgress: 0.25), 25_000, "四分之一")
            h.expectEqual(timeline.timeMS(forProgress: 1.0), 100_000, "末尾")
        }

        h.test("往返换算不丢精度") {
            for time in stride(from: 0, through: 100_000, by: 7_777) {
                let progress = timeline.progress(forTimeMS: time)
                let back = timeline.timeMS(forProgress: progress)
                h.expect(abs(back - time) <= 1, "\(time) → \(back)")
            }
        }

        h.test("越界被夹紧") {
            h.expectEqual(timeline.progress(forTimeMS: -500), 0.0, "负数")
            h.expectEqual(timeline.progress(forTimeMS: 999_999), 1.0, "超出")
            h.expectEqual(timeline.timeMS(forProgress: -1), 0, "负比例")
            h.expectEqual(timeline.timeMS(forProgress: 2), 100_000, "超比例")
        }

        h.test("像素坐标换算") {
            h.expectEqual(timeline.x(forTimeMS: 50_000, width: 400), 200.0, "中点像素")
            h.expectEqual(timeline.timeMS(forX: 100, width: 400), 25_000, "100px → 25s")
        }

        h.test("宽度为 0 不崩") {
            h.expectEqual(timeline.timeMS(forX: 100, width: 0), 0, "返回 0")
        }

        h.test("时间段对应的峰值范围") {
            let range = timeline.bucketRange(forStartMS: 10_000, endMS: 20_000)
            h.expectNotNil(range, "有范围")
            h.expectEqual(range?.lowerBound, 10, "起始桶")
            h.expectEqual(range?.upperBound, 20, "结束桶")
        }

        h.test("空波形不崩") {
            let empty = WaveformTimeline(durationMS: 0, peaks: [])
            h.expectNil(empty.bucketIndex(forTimeMS: 100), "没有桶")
            h.expectNil(empty.bucketRange(forStartMS: 0, endMS: 100), "没有范围")
        }

        h.test("吸附到附近最响处") {
            let peaks: [Float] = [0.1, 0.1, 0.9, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
            let t = WaveformTimeline(durationMS: 10_000, peaks: peaks)
            let snapped = t.loudestNear(timeMS: 2_000, windowMS: 1_500)
            h.expect(abs(snapped - 2_500) <= 500, "吸附到 2.5s 附近，实际 \(snapped)ms")
        }
    }

    // ─────────────────────────────────────────────────────────
    h.suite("从音频读波形") {
        /// 造一个"前半段响、后半段静"的 WAV
        func makeTestWAV(loudFirstHalf: Bool) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("waveform-test-\(UUID().uuidString).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(44_100)   // 1 秒
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            let data = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                let isLoud = loudFirstHalf ? (i < Int(frames) / 2) : (i >= Int(frames) / 2)
                data[i] = isLoud ? 0.8 : 0.02
            }
            try file.write(from: buffer)
            return url
        }

        h.test("能读出波形") {
            guard let url = try? makeTestWAV(loudFirstHalf: true) else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? WaveformLoader.load(url: url, buckets: 20) else {
                h.expect(false, "读取失败"); return
            }
            h.expect(!data.peaks.isEmpty, "有峰值")
            h.expect(data.durationMS > 900, "时长约 1 秒，实际 \(data.durationMS)ms")
        }

        h.test("峰值能反映音量分布") {
            guard let url = try? makeTestWAV(loudFirstHalf: true) else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? WaveformLoader.load(url: url, buckets: 20) else { return }
            let firstHalf = data.peaks.prefix(10).reduce(0, +) / 10
            let secondHalf = data.peaks.suffix(10).reduce(0, +) / 10
            h.expect(firstHalf > secondHalf, "前半段更响（\(firstHalf) > \(secondHalf)）")
        }

        h.test("峰值归一化到 0…1") {
            guard let url = try? makeTestWAV(loudFirstHalf: true) else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? WaveformLoader.load(url: url, buckets: 30) else { return }
            h.expect(data.peaks.allSatisfy { $0 >= 0 && $0 <= 1 }, "都在范围内")
            h.expect(data.peaks.contains { $0 > 0.9 }, "有接近 1 的峰")
        }

        h.test("不存在的文件不会崩") {
            let url = URL(fileURLWithPath: "/tmp/不存在的音频-\(UUID().uuidString).wav")
            h.expectNil(try? WaveformLoader.load(url: url), "抛错而不是崩溃")
        }
    }
}
