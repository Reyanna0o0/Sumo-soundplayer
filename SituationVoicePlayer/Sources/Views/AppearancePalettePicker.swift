import SwiftUI

/// Three visible choices; scrolling reveals the remaining appearance without
/// shrinking the labels or changing the selected appearance while scrolling.
struct AppearancePalettePicker: View {
    @Binding var selection: AppPalette
    @State private var initialAnchor: UnitPoint

    init(selection: Binding<AppPalette>) {
        _selection = selection
        // 初次打开时让紫色可见；后续点击不改变用户手动滚动的位置。
        _initialAnchor = State(initialValue: selection.wrappedValue == .purple ? .trailing : .leading)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(44, geometry.size.width / 3)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(AppPalette.allCases) { palette in
                        Button { selection = palette } label: {
                            Text(palette.name)
                                .font(.subheadline.weight(selection == palette ? .semibold : .regular))
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(selection == palette ? AppTheme.ink : AppTheme.secondary)
                                .frame(width: width - 6, height: 34)
                                .background {
                                    if selection == palette {
                                        RoundedRectangle(cornerRadius: 7).fill(AppTheme.card)
                                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    }
                                }
                                .frame(width: width, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == palette ? .isSelected : [])
                        .accessibilityIdentifier("palette-" + palette.rawValue)
                        .id(palette)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .background(AppTheme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .defaultScrollAnchor(initialAnchor, for: .initialOffset)
        }
        .frame(height: 44)
        .accessibilityIdentifier("appPalettePicker")
    }
}
