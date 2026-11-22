import SwiftUI

/// Measure the fixed call controls first, then offer only the remaining space
/// to the subtitle reader. A long cue can never enlarge this screen layout.
struct CallOverlayLayout: Layout {
    let size: CGSize
    let subtitleInMiddle: Bool

    // Child order: header, subtitle, controls, hangup, utilities.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5 else { return }
        let frames = frames(in: bounds.size, subviews: subviews)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(in size: CGSize, subviews: Subviews) -> [CGRect] {
        func height(_ index: Int, width: CGFloat, maximum: CGFloat? = nil) -> CGFloat {
            let measured = subviews[index].sizeThatFits(ProposedViewSize(width: max(0, width), height: maximum)).height
            return max(0, min(measured.isFinite ? measured : 0, maximum ?? .infinity))
        }
        func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: x, y: y, width: max(0, width), height: max(0, height))
        }

        if !CallScreenLayout.isLandscape(size) {
            let width = max(0, size.width - 44)
            let controlsHeight = height(2, width: width)
            let hangupHeight = height(3, width: width)
            let utilitiesHeight = height(4, width: width)
            let fixedHeight = controlsHeight + hangupHeight + utilitiesHeight
            let bottom: CGFloat = min(24, max(0, size.height - fixedHeight))
            let gap: CGFloat = min(16, max(0, (size.height - fixedHeight - bottom) / 3))
            let headerBudget = max(0, size.height - fixedHeight - bottom - 3 * gap - 8)
            let headerHeight = min(height(0, width: size.width), headerBudget)
            let subtitleBudget = max(0, headerBudget - headerHeight)
            let subtitleHeight = height(1, width: width, maximum: subtitleBudget)
            var frames = Array(repeating: CGRect.zero, count: 5)
            frames[0] = rect(x: 0, y: 0, width: size.width, height: headerHeight)
            var y = size.height - bottom - fixedHeight - subtitleHeight - 3 * gap
            let order = subtitleInMiddle ? [1, 2, 3, 4] : [2, 3, 1, 4]
            let heights = [headerHeight, subtitleHeight, controlsHeight, hangupHeight, utilitiesHeight]
            for index in order {
                frames[index] = rect(x: 22, y: y, width: width, height: heights[index])
                y += heights[index] + gap
            }
            return frames
        }

        let width = max(0, size.width - 36)
        let columnWidth = max(0, (width - 16) / 2)
        let rightX = 18 + columnWidth + 16
        let controlsHeight = height(2, width: columnWidth)
        let hangupHeight = height(3, width: columnWidth)
        let utilitiesHeight = height(4, width: width)
        let headerHeight = height(0, width: columnWidth)
        let bottom: CGFloat = 20
        let topHeight = max(0, size.height - bottom - utilitiesHeight - 6)
        var frames = Array(repeating: CGRect.zero, count: 5)
        frames[4] = rect(x: 18, y: size.height - bottom - utilitiesHeight,
                         width: width, height: utilitiesHeight)
        if subtitleInMiddle {
            let budget = max(0, topHeight - controlsHeight - hangupHeight - 16)
            let subtitleHeight = height(1, width: columnWidth, maximum: budget)
            let contentHeight = subtitleHeight + controlsHeight + hangupHeight + 16
            let y = max(0, (topHeight - contentHeight) / 2)
            frames[0] = rect(x: 18, y: 0, width: columnWidth, height: min(headerHeight, topHeight))
            frames[1] = rect(x: rightX, y: y, width: columnWidth, height: subtitleHeight)
            frames[2] = rect(x: rightX, y: y + subtitleHeight + 8, width: columnWidth, height: controlsHeight)
            frames[3] = rect(x: rightX, y: y + subtitleHeight + controlsHeight + 16,
                             width: columnWidth, height: hangupHeight)
        } else {
            let minimumTop = max(headerHeight, controlsHeight + hangupHeight + 8)
            let subtitleWidth = min(660, width)
            let budget = max(0, topHeight - minimumTop - 6)
            let subtitleHeight = height(1, width: subtitleWidth, maximum: budget)
            let upperHeight = max(0, topHeight - subtitleHeight - 6)
            let y = max(0, (upperHeight - controlsHeight - hangupHeight - 8) / 2)
            frames[0] = rect(x: 18, y: 0, width: columnWidth, height: min(headerHeight, upperHeight))
            frames[1] = rect(x: (size.width - subtitleWidth) / 2, y: upperHeight + 6,
                             width: subtitleWidth, height: subtitleHeight)
            frames[2] = rect(x: rightX, y: y, width: columnWidth, height: controlsHeight)
            frames[3] = rect(x: rightX, y: y + controlsHeight + 8, width: columnWidth, height: hangupHeight)
        }
        return frames
    }
}
