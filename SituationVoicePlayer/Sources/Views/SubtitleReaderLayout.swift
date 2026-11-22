import Foundation
import CoreGraphics

/// 拖条只改变这一页的分区。0 保留原位置，正/负值分别向封面/台词让出空间。
struct SubtitleReaderLayout {
    let size: CGSize
    let landscape: Bool
    let minimum: CGFloat
    let standard: CGFloat
    let maximum: CGFloat
    let boundary: CGFloat
    let value: CGFloat

    init(size: CGSize, value: CGFloat) {
        self.size = size
        landscape = size.width > size.height && size.width >= 560
        let extent = landscape ? size.width : size.height
        let legacy = landscape ? min(size.width * 0.47 + 8, max(0, size.width - 324)) : size.height * 0.26
        // 下方同时容纳台词、提示和控制条；横向保留现有控制条所需的最小宽度。
        maximum = max(legacy, extent - (landscape ? min(324, extent) : min(extent, max(260, extent * 0.32))))
        // 极窄横屏原先已经顶到324pt栏宽上限。最多左移20pt留出真实拖动行程，
        // 不缩窄文字/控制栏；竖屏及有足够行程的横屏默认值保持原样。
        standard = landscape ? max(min(60, legacy), min(legacy, maximum - 20)) : legacy
        minimum = min(standard, landscape ? 60 : 30)
        self.value = min(1, max(-1, value.isFinite ? value : 0))
        boundary = standard + self.value * (self.value >= 0 ? maximum - standard : standard - minimum)
    }

    var readerLeading: CGFloat { landscape ? boundary : 0 }
    var readerTop: CGFloat { landscape ? 0 : boundary }
    var framingFraction: CGFloat { max(0, value) }
    var isAdjusted: Bool { abs(value) > 0.0001 }

    func value(at position: CGFloat) -> CGFloat {
        let distance = position - standard
        let travel = distance >= 0 ? maximum - standard : standard - minimum
        guard travel > 0 else { return 0 }
        return min(1, max(-1, distance / travel))
    }
}

/// 同一张图在 fill 与 fit 之间连续改变尺寸，不更换图层或拉伸图片。
enum CoverFraming {
    static func size(image: CGSize, container: CGSize, fraction: CGFloat) -> CGSize {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let x = container.width / image.width, y = container.height / image.height
        let fill = max(x, y), fit = min(x, y)
        let amount = min(1, max(0, fraction.isFinite ? fraction : 0))
        let scale = fill + (fit - fill) * amount
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
