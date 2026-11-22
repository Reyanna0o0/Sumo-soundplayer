import SwiftUI

extension AppTheme {
    /// A native hierarchical style inherits its parent foreground, including controls drawn on materials.
    static func textStyle<Native: ShapeStyle>(_ native: Native, _ themed: Color) -> AnyShapeStyle {
        usesCustomPalette ? AnyShapeStyle(themed) : AnyShapeStyle(native)
    }

    static var primaryText: AnyShapeStyle { textStyle(.primary, ink) }
    static var secondaryText: AnyShapeStyle { textStyle(.secondary, secondary) }
    static var tertiaryText: AnyShapeStyle { textStyle(.tertiary, tertiary) }
}

extension View {
    func porcelainPlainRow(_ color: Color = AppTheme.libraryRowSurface) -> some View {
        listRowBackground(AppTheme.usesCustomPalette ? color : nil)
            .listRowSeparatorTint(AppTheme.usesCustomPalette ? AppTheme.separator : nil)
    }

    func porcelainListBackground(_ color: Color) -> some View {
        scrollContentBackground(AppTheme.usesCustomPalette ? .hidden : .automatic)
            .appPageBackground(AppTheme.painted(.clear, color))
    }

    @ViewBuilder func porcelainCoverPopover() -> some View {
        if AppTheme.usesCustomPalette {
            presentationBackground(AppTheme.groupedCard).tint(AppTheme.accent)
        } else {
            self
        }
    }
}
