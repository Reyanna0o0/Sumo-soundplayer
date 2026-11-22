import Foundation
import AVFoundation

/// 基于 `AVAudioEngine` 的音频播放引擎。
///
/// 为什么不用 `AVPlayer`：
/// - 你要的 EQ / 变速 / 变调 / 淡入淡出都要插在"解码之后、出声之前"，
///   `AVPlayer` 不给这个位置
/// - `AVAudioEngine` 的节点链可以任意插处理器
///
/// 信号链：
/// ```
/// AVAudioPlayerNode → TimePitch(变速变调) → EQ(均衡器) → 主混音器 → 输出
/// ```
@MainActor
final class AudioPlaybackEngine {

    enum EngineError: LocalizedError {
        case unsupportedFormat(String)
        case fileNotReadable(String)
        case audioNotDecodable(String)
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return InterfaceLocalization.text("暂不支持 \(ext.uppercased()) 格式。")
            case .fileNotReadable(let path):
                return InterfaceLocalization.text("无法打开「\((path as NSString).lastPathComponent)」，请确认文件已下载且原文件夹仍可访问。")
            case .audioNotDecodable(let path):
                return InterfaceLocalization.text("无法解码「\((path as NSString).lastPathComponent)」的音频内容，请尝试同曲目的其他版本。")
            case .engineStartFailed(let message):
                return InterfaceLocalization.text("音频引擎启动失败：\(message)")
            }
        }
    }

    // MARK: - 节点

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 10)

    // MARK: - 状态

    private var file: AVAudioFile?
    /// 当前这首的总帧数
    private var totalFrames: AVAudioFramePosition = 0
    /// 本次 play 的起点（帧），seek 会改它
    private var seekFrame: AVAudioFramePosition = 0
    private var scheduledGeneration = 0
    private(set) var durationMS: Int = 0

    /// 播完一首的回调（用于队列自动前进）
    var onTrackFinished: (() -> Void)?

    private var volume: Float = 1.0
    private var fadeTask: Task<Void, Never>?

    // MARK: - 初始化

    init() {
        configureGraph()
        configureEqualizerDefaults()
    }

    private func configureGraph() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(equalizer)

        // 先按一个通用格式连接；真正加载文件时会用文件格式重连
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)

        timePitch.rate = 1.0
        timePitch.pitch = 0
        timePitch.overlap = 8.0   // 变速时减少断裂感
    }

    private func configureEqualizerDefaults() {
        // 默认全部平直；界面调整时再改
        for band in equalizer.bands {
            band.filterType = .parametric
            band.frequency = 1_000
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = true
        }
        equalizer.globalGain = 0
    }

    // MARK: - 生命周期

    var isEngineRunning: Bool { engine.isRunning }

    private func startEngineIfNeeded() throws {
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw EngineError.engineStartFailed(error.localizedDescription)
        }
    }

    // MARK: - 加载

    /// 加载一首音频文件
    func load(url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let supported: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "wave", "aiff", "aif", "flac", "caf", "mp4", "m4v", "mov"]
        guard supported.contains(ext) else {
            throw EngineError.unsupportedFormat(ext)
        }

        stop()

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            logReadError(error, url: url, stage: "打开")
            throw EngineError.fileNotReadable(url.path)
        }

        let format = audioFile.processingFormat
        let sampleRate = format.sampleRate
        guard audioFile.length > 0, sampleRate.isFinite, sampleRate > 0, format.channelCount > 0 else {
            throw EngineError.audioNotDecodable(url.path)
        }
        // 能读取文件头不等于能解码音频。用独立句柄试读，正式播放句柄仍在第 0 帧；
        // 不对压缩文件设置 framePosition，部分 MP3 解码器的 seek 会直接崩溃。
        do {
            let probe = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: probe.processingFormat, frameCapacity: 1024) else {
                throw EngineError.audioNotDecodable(url.path)
            }
            try probe.read(into: buffer, frameCount: AVAudioFrameCount(min(1024, probe.length)))
            guard buffer.frameLength > 0 else { throw EngineError.audioNotDecodable(url.path) }
        } catch {
            logReadError(error, url: url, stage: "解码首段")
            throw EngineError.audioNotDecodable(url.path)
        }

        file = audioFile
        totalFrames = audioFile.length
        seekFrame = 0
        durationMS = Int(Double(totalFrames) / sampleRate * 1000)

        // stop() 已停止整个引擎。运行时逐段改变采样率，会让 EQ 的输入输出
        // 暂时不一致并抛出无法被 Swift catch 捕获的系统异常（-10868）。
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(equalizer)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
    }

    private func logReadError(_ error: Error, url: URL, stage: String) {
        let underlying = error as NSError
        DebugLog.write("音频\(stage)失败 \(url.lastPathComponent)：\(underlying.domain) / \(underlying.code) / \(underlying.localizedDescription)")
    }

    // MARK: - 播放控制

    func play(fromMilliseconds startMS: Int = 0, fadeIn: Double = 0) throws {
        guard file != nil else { return }
        try startEngineIfNeeded()
        seek(toMilliseconds: startMS, playing: false)
        scheduleFromCurrentPosition()
        player.play()

        if fadeIn > 0 {
            applyFade(from: 0, to: volume, duration: fadeIn)
        } else {
            player.volume = volume
        }
    }

    func pause(fadeOut: Double = 0, completion: @escaping () -> Void = {}) {
        scheduledGeneration += 1
        fadeTask?.cancel()
        fadeTask = nil
        let finish = { [weak self] in
            self?.player.pause()
            self?.engine.pause()
            completion()
        }
        if fadeOut > 0, engine.isRunning, player.isPlaying {
            applyFade(from: player.volume, to: 0, duration: fadeOut, completion: finish)
        } else {
            finish()
        }
    }

    func stop() {
        fadeTask?.cancel()
        fadeTask = nil
        scheduledGeneration += 1
        player.stop()
        engine.stop()
        file = nil
        totalFrames = 0
        seekFrame = 0
        durationMS = 0
    }

    /// 跳转到指定毫秒
    func seek(toMilliseconds positionMS: Int, playing: Bool) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let targetFrames = AVAudioFramePosition(Double(max(0, positionMS)) * sampleRate / 1000)
        seekFrame = min(max(0, targetFrames), totalFrames)

        fadeTask?.cancel()
        fadeTask = nil
        player.volume = volume
        scheduledGeneration += 1
        player.stop()
        if playing && engine.isRunning {
            scheduleFromCurrentPosition()
            player.play()
        }
    }

    // MARK: - 位置

    /// 当前播放位置（毫秒）
    var currentPositionMS: Int {
        guard let file else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }

        var frames = seekFrame
        if player.isPlaying,
           let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            frames += playerTime.sampleTime
        }
        return Int(Double(frames) / sampleRate * 1000)
    }

    var isPlaying: Bool { player.isPlaying }

    // MARK: - 音效

    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = Float(AudioMath.clampRate(Double(newValue))) }
    }

    /// 音调偏移（音分）
    var pitchCents: Float {
        get { timePitch.pitch }
        set { timePitch.pitch = Float(AudioMath.clampCents(Double(newValue))) }
    }

    /// 用半音设置音调
    func setPitch(semitones: Double) {
        pitchCents = Float(AudioMath.cents(fromSemitones: AudioMath.clampSemitones(semitones)))
    }

    /// 用 A4 基准频率设置音调（432Hz 调音就传 432）
    func setTuning(a4: Double) {
        pitchCents = Float(AudioMath.centsFromStandardTuning(a4: a4))
    }

    var masterVolume: Float {
        get { volume }
        set {
            volume = min(max(newValue, 0), 1)
            if fadeTask == nil { player.volume = volume }
        }
    }

    /// 设置均衡器（每段：中心频率、增益 dB、带宽）
    func setEqualizer(_ bands: [EqualizerBand]) {
        for (index, band) in equalizer.bands.enumerated() {
            if index < bands.count {
                let config = bands[index]
                band.filterType = .parametric
                band.frequency = config.frequency
                band.bandwidth = config.bandwidth
                band.gain = config.gain
                band.bypass = !config.enabled
            } else {
                band.bypass = true
            }
        }
    }

    var equalizerEnabled: Bool {
        get { equalizer.bypass == false }
        set { equalizer.bypass = !newValue }
    }

    // MARK: - 淡入淡出

    private func applyFade(from start: Float, to end: Float, duration: Double, completion: (() -> Void)? = nil) {
        fadeTask?.cancel()
        player.volume = start

        let steps = max(1, Int(duration * 30))   // 约 30fps 的增益更新
        let interval = duration / Double(steps)

        fadeTask = Task { [weak self] in
            guard let self else { return }
            for step in 1...steps {
                if Task.isCancelled { return }
                let progress = Float(step) / Float(steps)
                self.player.volume = start + (end - start) * progress
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            self.fadeTask = nil
            completion?()
        }
    }

    // MARK: - 内部

    /// 从 `seekFrame` 开始排一段音频到播放节点
    private func scheduleFromCurrentPosition() {
        guard let file else { return }
        let remaining = totalFrames - seekFrame
        scheduledGeneration += 1
        let generation = scheduledGeneration
        guard remaining > 0 else {
            Task { @MainActor [weak self] in
                guard let self, generation == self.scheduledGeneration else { return }
                self.onTrackFinished?()
            }
            return
        }

        player.scheduleSegment(
            file,
            startingFrame: seekFrame,
            frameCount: AVAudioFrameCount(clamping: remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            // 回调在后台线程
            Task { @MainActor in
                guard let self else { return }
                guard generation == self.scheduledGeneration else { return }
                self.onTrackFinished?()
            }
        }
    }
}

/// 均衡器一段的配置
struct EqualizerBand: Equatable, Sendable {
    var frequency: Float
    var gain: Float
    var bandwidth: Float = 1.0
    var enabled: Bool = true

    /// 10 段标准均衡器的默认频率
    static let defaultFrequencies: [Float] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    /// 平直（全部 0dB）
    static var flat: [EqualizerBand] {
        defaultFrequencies.map { EqualizerBand(frequency: $0, gain: 0, enabled: false) }
    }
}
