import SwiftUI
import UIKit

/// 只为滚动列表已装入的台词登记位置。换句时旧行和新行可以同时存在。
@MainActor
final class SubtitleRowAnchor {
    enum Result { case aligned, moved, missingRow, interacting }

    struct ReadingPosition {
        let id: UUID
        let fraction: Double
    }

    /// 取消 Swift 定位任务不会停止已交给系统的动画；抓住分界条时一并停住它。
    func stopScrolling() {
        guard let loaded = markers.objectEnumerator() else { return }
        for case let marker as UIView in loaded {
            guard marker.window != nil else { continue }
            var ancestor = marker.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            if let scroll = ancestor as? UIScrollView {
                scroll.stopScrollingAndZooming()
                return
            }
        }
    }

    /// 分区开始变化前保存可见台词及句内位置，不保存屏幕像素。
    func captureReading(ids: [UUID], topInset: CGFloat = 28) -> ReadingPosition? {
        for id in ids {
            guard let marker = markers.object(forKey: id as NSUUID), let window = marker.window,
                  marker.bounds.height > 0 else { continue }
            var ancestor = marker.superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else { continue }
            let row = marker.convert(marker.bounds, to: window)
            let viewport = scroll.convert(scroll.bounds, to: window)
            let top = viewport.minY + topInset
            if row.maxY > top, row.minY < viewport.maxY - 22 {
                return ReadingPosition(id: id, fraction: Double(min(1, max(0, (top - row.minY) / row.height))))
            }
        }
        return nil
    }

    func restore(_ position: ReadingPosition, using proxy: ScrollViewProxy) async {
        var aligned = false
        for attempt in 0..<12 {
            guard !Task.isCancelled else { return }
            switch restoreReading(id: position.id, fraction: position.fraction) {
            case .aligned:
                if aligned { return }
                aligned = true
            case .moved: aligned = false
            case .missingRow:
                if attempt == 0 || attempt == 4 { proxy.scrollTo(position.id, anchor: .top) }
            case .interacting: return
            }
            do { try await Task.sleep(for: .milliseconds(70)) } catch { return }
        }
    }

    fileprivate let markers = NSMapTable<NSUUID, UIView>.strongToWeakObjects()

    /// 未打轴阅读独立使用顶部文字锚点，不改动带轴字幕的中线定位。
    func restoreReading(id: UUID, fraction: Double, topInset: CGFloat = 28) -> Result {
        guard let marker = markers.object(forKey: id as NSUUID),
              let window = marker.window, marker.bounds.height > 0 else { return .missingRow }
        var ancestor = marker.superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView, scroll.bounds.height > 0 else { return .missingRow }
        if scroll.isTracking || scroll.isDragging || scroll.isDecelerating { return .interacting }
        let row = marker.convert(marker.bounds, to: window)
        let viewport = scroll.convert(scroll.bounds, to: window)
        let delta = row.minY + row.height * CGFloat(fraction) - viewport.minY - topInset
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let target = min(max(scroll.contentOffset.y + delta, minimum), maximum)
        guard abs(target - scroll.contentOffset.y) > 1.5 else { return .aligned }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
        return .moved
    }

    func center(id: UUID, animated: Bool, targetY: CGFloat? = nil) -> Result {
        guard let marker = markers.object(forKey: id as NSUUID),
              let window = marker.window, marker.bounds.height > 0 else {
            return .missingRow
        }
        var ancestor = marker.superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView, scroll.bounds.height > 0 else { return .missingRow }
        if scroll.isTracking || scroll.isDragging || scroll.isDecelerating { return .interacting }

        let row = marker.convert(marker.bounds, to: window)
        let viewport = scroll.convert(scroll.bounds, to: window)
        let edge = min(28, viewport.height / 2)
        let target = min(max(targetY ?? window.bounds.midY, viewport.minY + edge), viewport.maxY - edge)
        let delta = row.midY - target
        guard abs(delta) > 1.5 else { return .aligned }

        // 保留水平位置。垂直边界包含 iOS 实际应用的内容内边距。
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        var offset = scroll.contentOffset
        offset.y = min(max(offset.y + delta, minimum), maximum)
        scroll.setContentOffset(offset, animated: animated)
        return .moved
    }
}

struct SubtitleRowMarker: UIViewRepresentable {
    let id: UUID
    let anchor: SubtitleRowAnchor

    final class Coordinator {
        weak var anchor: SubtitleRowAnchor?
        var id: UUID?

        @MainActor func unregister(_ marker: UIView) {
            if let id, let markers = anchor?.markers,
               markers.object(forKey: id as NSUUID) === marker {
                markers.removeObject(forKey: id as NSUUID)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let marker = UIView()
        marker.isUserInteractionEnabled = false
        marker.accessibilityElementsHidden = true
        return marker
    }

    func updateUIView(_ marker: UIView, context: Context) {
        let registration = context.coordinator
        if registration.id != id || registration.anchor !== anchor {
            registration.unregister(marker)
            registration.anchor = anchor
            registration.id = id
        }
        anchor.markers.setObject(marker, forKey: id as NSUUID)
    }

    static func dismantleUIView(_ marker: UIView, coordinator: Coordinator) {
        coordinator.unregister(marker)
    }
}
