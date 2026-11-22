import SwiftUI

extension AppTheme {
    static var libraryRowSurface: Color { isPurple ? .clear : card }
}

/// Feather the viewport itself. Buttons, fixed headers, and the tab bar remain
/// outside the effect and keep their full hit areas.
struct ScrollContentEdges: ViewModifier {
    var topBackdrop: Color?
    var bottomBackdrop: Color?
    var fadesBottom = true

    static var library: Self {
        Self(topBackdrop: AppTheme.painted(Color(uiColor: .systemBackground), AppTheme.libraryHeaderSurface),
             bottomBackdrop: AppTheme.painted(Color(uiColor: .systemBackground), AppTheme.background))
    }

    static var topOnly: Self { Self(fadesBottom: false) }

    @State private var overflow = EdgeOverflow()

    func body(content: Content) -> some View {
        if !fadesBottom && topBackdrop == nil && bottomBackdrop == nil {
            // A mask around the root Form/ScrollView can interfere with native
            // large-title scroll tracking. Let the navigation system own this
            // edge and its actual title/safe-area position instead.
            if #available(iOS 26.0, *) {
                content.scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                content
            }
        } else {
            libraryEdges(content)
        }
    }

    private func libraryEdges(_ content: Content) -> some View {
        edges(content)
            .onScrollGeometryChange(for: EdgeOverflow.self) { geometry in
                EdgeOverflow(above: geometry.contentOffset.y + geometry.contentInsets.top,
                             below: geometry.contentSize.height + geometry.contentInsets.bottom
                                 - geometry.contentOffset.y - geometry.containerSize.height)
            } action: { _, value in overflow = value }
    }

    @ViewBuilder private func edges(_ content: Content) -> some View {
        if !AppTheme.isPurple, let topBackdrop, let bottomBackdrop {
            // The library switches surface colors at these boundaries. Keep a
            // short blend at rest, and feather clipped rows further as they pass.
            content
                .overlay(alignment: .top) {
                    ramp(topBackdrop, fromTop: true)
                        .frame(height: 14 + 16 * overflow.above)
                }
                .overlay(alignment: .bottom) {
                    ramp(bottomBackdrop, fromTop: false)
                        .frame(height: 16 + 22 * overflow.below)
                }
        } else {
            // Fade overflowing rows into the page gradient at their exact position.
            content.mask {
                Rectangle()
                    .overlay(alignment: .top) {
                        ramp(.black, fromTop: true)
                            .frame(height: 30).opacity(overflow.above)
                            .blendMode(.destinationOut)
                    }
                    .overlay(alignment: .bottom) {
                        if fadesBottom {
                            ramp(.black, fromTop: false)
                                .frame(height: 38).opacity(overflow.below)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
        }
    }

    private func ramp(_ color: Color, fromTop: Bool) -> some View {
        LinearGradient(stops: [
            .init(color: color, location: 0),
            .init(color: color.opacity(0.895), location: 0.2),
            .init(color: color.opacity(0.648), location: 0.4),
            .init(color: color.opacity(0.352), location: 0.6),
            .init(color: color.opacity(0.105), location: 0.8),
            .init(color: color.opacity(0), location: 1)
        ], startPoint: fromTop ? .top : .bottom, endPoint: fromTop ? .bottom : .top)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private struct EdgeOverflow: Equatable {
        let above: CGFloat
        let below: CGFloat

        init(above: CGFloat = 0, below: CGFloat = 0) {
            self.above = min(max(above / 30, 0), 1)
            self.below = min(max(below / 38, 0), 1)
        }
    }
}
