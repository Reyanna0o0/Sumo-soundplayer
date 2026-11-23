import SwiftUI

struct AppearancePalettePicker: View {
    @Binding var selection: AppPalette
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(AppPalette.allCases) { palette in
                Button { selection = palette } label: {
                    Text(palette.name)
                        .font(.subheadline.weight(selection == palette ? .semibold : .regular))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(selection == palette ? AppTheme.ink : AppTheme.secondary)
                        .padding(8).frame(maxWidth: .infinity, minHeight: 44)
                        .background(selection == palette ? AppTheme.card : AppTheme.surface.opacity(0.65),
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == palette ? .isSelected : [])
                .accessibilityIdentifier("palette-" + palette.rawValue)
            }
        }.accessibilityIdentifier("appPalettePicker")
    }
}
