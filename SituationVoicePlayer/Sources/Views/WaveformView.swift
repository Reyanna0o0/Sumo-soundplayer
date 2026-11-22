import SwiftUI

/// 波形时间轴：显示峰值、播放进度，可拖动跳转。
struct WaveformView: View {
    let timeline: WaveformTimeline
    /// 当前播放位置
    let positionMS: Int
    /// 拖到某处时回调（松手才真正跳转）
    let onSeek: (Int) -> Void
    /// 拖动过程中的实时回调（用于更新时间显示）
    var onScrub: ((Int?) -> Void)? = nil

    @State private var previewMS: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = timeline.progress(forTimeMS: previewMS ?? positionMS)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                Canvas { context, size in
                    drawPeaks(in: &context, size: size)
                }
                Rectangle()
                    .fill(AppTheme.accent.opacity(0.18))
                    .frame(width: width * progress)
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: 6, height: 34)
                    .offset(x: max(0, min(width - 6, width * progress - 3)))
                WaveformSeekControl(
                    positionMS: previewMS ?? positionMS, timeline: timeline,
                    preview: { ms in
                        previewMS = ms
                        onScrub?(ms)
                    }, commit: onSeek
                )
            }
        }
        .frame(height: 56)
    }

    private func drawPeaks(in context: inout GraphicsContext, size: CGSize) {
        guard !timeline.peaks.isEmpty else {
            // 还没加载出波形时画一条中线，避免整块空白
            let mid = CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)
            context.fill(Path(mid), with: .color(Color.secondary.opacity(0.25)))
            return
        }

        let count = timeline.peaks.count
        let barWidth = size.width / CGFloat(count)
        let midY = size.height / 2

        var path = Path()
        for (index, peak) in timeline.peaks.enumerated() {
            let x = CGFloat(index) * barWidth + barWidth / 2
            let normalized = CGFloat(min(1, max(0, peak)))
            // 给个最小值，静音处也能看到细线
            let amplitude = max(0.6, normalized * (size.height / 2 - 2))
            path.move(to: CGPoint(x: x, y: midY - amplitude))
            path.addLine(to: CGPoint(x: x, y: midY + amplitude))
        }
        context.stroke(path, with: .color(AppTheme.accent.opacity(0.55)), lineWidth: max(1, barWidth * 0.65))
    }
}

// UIScrollView leaves slider tracking to the control. Start anywhere on the waveform,
// and keep playback ticks separate from the in-progress finger position.
private struct WaveformSeekControl: UIViewRepresentable {
    let positionMS: Int
    let timeline: WaveformTimeline
    let preview: (Int?) -> Void
    let commit: (Int) -> Void

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TrackingSlider, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 200, height: 56))
    }

    func makeUIView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider()
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        slider.setThumbImage(blank, for: .normal)
        slider.setMinimumTrackImage(blank, for: .normal)
        slider.setMaximumTrackImage(blank, for: .normal)
        slider.accessibilityLabel = L10n.text("播放进度")
        slider.accessibilityIdentifier = "waveformSeek"
        return slider
    }

    func updateUIView(_ slider: TrackingSlider, context: Context) {
        if !slider.isTracking { slider.value = Float(timeline.progress(forTimeMS: positionMS)) }
        slider.accessibilityValue = SubtitleTime.clock(positionMS)
        slider.isEnabled = context.environment.isEnabled
        slider.preview = { progress in preview(progress.map(timeline.timeMS(forProgress:))) }
        slider.commit = { progress in commit(timeline.timeMS(forProgress: progress)) }
    }

    final class TrackingSlider: UISlider {
        var preview: ((Double?) -> Void)?
        var commit: ((Double) -> Void)?

        private func updatePosition(_ touch: UITouch) {
            value = Float(min(1, max(0, touch.location(in: self).x / max(1, bounds.width))))
            preview?(Double(value))
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            updatePosition(touch)
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            updatePosition(touch)
            return true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            if let touch { updatePosition(touch) }
            commit?(Double(value))
            preview?(nil)
        }

        override func cancelTracking(with event: UIEvent?) {
            preview?(nil)
        }

        override func accessibilityIncrement() { adjust(by: 0.05) }
        override func accessibilityDecrement() { adjust(by: -0.05) }

        private func adjust(by step: Float) {
            value = min(1, max(0, value + step))
            commit?(Double(value))
        }
    }
}
