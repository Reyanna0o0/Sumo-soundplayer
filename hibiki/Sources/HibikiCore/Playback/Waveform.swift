import Foundation
import AVFoundation

/// 波形数据：把整段音频压缩成固定数量的峰值。
public struct WaveformData: Equatable, Sendable {
    /// 归一化到 0…1 的峰值
    public var peaks: [Float]
    /// 音频总时长
    public var durationMS: Int

    public init(peaks: [Float], durationMS: Int) {
        self.peaks = peaks
        self.durationMS = durationMS
    }

    public var isEmpty: Bool { peaks.isEmpty }

    public static let empty = WaveformData(peaks: [], durationMS: 0)
}

/// 从音频文件读波形。
public enum WaveformLoader {

    /// 读取波形
    /// - Parameters:
    ///   - url: 音频文件
    ///   - buckets: 想要多少个峰值点（界面宽度决定，一般 600~1200）
    public static func load(url: URL, buckets: Int = 800) throws -> WaveformData {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, buckets > 0 else { return .empty }

        let durationSeconds = Double(totalFrames) / format.sampleRate
        let durationMS = Int(durationSeconds * 1000)

        // 每次读一大块，按"块内最大绝对值"取峰
        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        let readSize = AVAudioFrameCount(min(Int64(qualityReadSize), max(Int64(framesPerBucket), 4096)))

        var peaks: [Float] = []
        peaks.reserveCapacity(buckets)

        var remainingInBucket = framesPerBucket
        var bucketMax: Float = 0
        var reachedEnd = false

        while !reachedEnd {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readSize) else { break }
            try file.read(into: buffer, frameCount: readSize)
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }

            guard let channelData = buffer.floatChannelData else { break }
            let channels = Int(format.channelCount)

            var index = 0
            while index < frameCount {
                var amplitude: Float = 0
                for channel in 0..<channels {
                    let value = abs(channelData[channel][index])
                    if value > amplitude { amplitude = value }
                }
                if amplitude > bucketMax { bucketMax = amplitude }

                index += 1
                remainingInBucket -= 1
                if remainingInBucket == 0 {
                    peaks.append(bucketMax)
                    bucketMax = 0
                    remainingInBucket = framesPerBucket
                    if peaks.count >= buckets { reachedEnd = true; break }
                }
            }

            if buffer.frameLength < readSize { break }
        }
        if peaks.count < buckets, remainingInBucket < framesPerBucket {
            peaks.append(bucketMax)
        }

        return WaveformData(
            peaks: normalize(peaks, targetBuckets: buckets),
            durationMS: durationMS
        )
    }

    /// 归一化：把最大峰值拉到 1.0，太小的保持原样（避免放大底噪）
    static func normalize(_ peaks: [Float], targetBuckets: Int) -> [Float] {
        guard let maxValue = peaks.max(), maxValue > 0 else {
            return Array(repeating: 0, count: max(min(peaks.count, targetBuckets), targetBuckets))
                .isEmpty ? peaks : peaks
        }
        let scale = 1.0 / maxValue
        return peaks.map { min(1.0, $0 * scale) }
    }

    private static let qualityReadSize = 65_536
}

/// 波形与时间/坐标的换算。
///
/// 单独抽出来是因为这是"拖动时间轴"最容易出 off-by-one 的地方，
/// 放在纯逻辑层才能写测试。
public struct WaveformTimeline: Equatable, Sendable {
    public var durationMS: Int
    public var peaks: [Float]

    public init(durationMS: Int, peaks: [Float]) {
        self.durationMS = max(1, durationMS)
        self.peaks = peaks
    }

    public init(data: WaveformData) {
        self.init(durationMS: data.durationMS, peaks: data.peaks)
    }

    /// 时间 → 横坐标比例（0…1）
    public func progress(forTimeMS timeMS: Int) -> Double {
        let clamped = min(max(0, timeMS), durationMS)
        return Double(clamped) / Double(durationMS)
    }

    /// 横坐标比例 → 时间
    public func timeMS(forProgress progress: Double) -> Int {
        let clamped = min(max(0, progress), 1)
        return Int((clamped * Double(durationMS)).rounded())
    }

    /// 时间 → 像素坐标
    public func x(forTimeMS timeMS: Int, width: Double) -> Double {
        progress(forTimeMS: timeMS) * width
    }

    /// 像素坐标 → 时间
    public func timeMS(forX x: Double, width: Double) -> Int {
        guard width > 0 else { return 0 }
        return timeMS(forProgress: x / width)
    }

    /// 某个时间点落在第几个峰值
    public func bucketIndex(forTimeMS timeMS: Int) -> Int? {
        guard !peaks.isEmpty else { return nil }
        let index = Int(progress(forTimeMS: timeMS) * Double(peaks.count))
        return min(max(0, index), peaks.count - 1)
    }

    /// 时间段在波形上覆盖的峰值范围（画字幕块用）
    public func bucketRange(forStartMS startMS: Int, endMS: Int) -> Range<Int>? {
        guard !peaks.isEmpty else { return nil }
        let start = Int(progress(forTimeMS: startMS) * Double(peaks.count))
        let end = Int(progress(forTimeMS: endMS) * Double(peaks.count))
        let clampedStart = min(max(0, start), peaks.count - 1)
        let clampedEnd = min(max(clampedStart + 1, end), peaks.count)
        return clampedStart..<clampedEnd
    }

    /// 找出某个时间附近最响的位置（用于"吸附到明显的声音起点"）
    public func loudestNear(timeMS: Int, windowMS: Int = 400) -> Int {
        guard !peaks.isEmpty else { return timeMS }
        let lower = max(0, timeMS - windowMS)
        let upper = min(durationMS, timeMS + windowMS)
        var bestTime = timeMS
        var bestPeak: Float = -1

        // 步长不要太细，避免一点点噪声就吸附走
        let step = max(10, (upper - lower) / 40)
        var probe = lower
        while probe <= upper {
            if let index = bucketIndex(forTimeMS: probe), peaks[index] > bestPeak {
                bestPeak = peaks[index]
                bestTime = probe
            }
            probe += step
        }
        return bestTime
    }
}
