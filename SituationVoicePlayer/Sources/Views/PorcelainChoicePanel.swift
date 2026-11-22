import SwiftUI

enum PorcelainChoicePanelColors {
    static var ink: Color { AppTheme.usesDarkPalette ? AppTheme.ink : AppTheme.rgb(0x353229) }
    static var check: Color { AppTheme.usesDarkPalette ? AppTheme.iconTint : AppTheme.rgb(0x746E60) }
    static var pressed: Color {
        if AppTheme.isPurple { return AppTheme.rgb(0x4F4763) }
        return AppTheme.rgb(AppTheme.isGraphite ? 0x424347 : 0xF6F3EB)
    }
    static var edge: Color { AppTheme.usesDarkPalette ? AppTheme.separator : AppTheme.rgb(0xE9E4D9) }
    static var shadow: Color { AppTheme.usesDarkPalette ? AppTheme.shadow : AppTheme.rgb(0x423E31) }
}

/// Shared by the library and sort selectors in appearances with custom menus.
struct PorcelainChoicePanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows.fixedSize(horizontal: false, vertical: true)
            ScrollView { rows }
                .scrollBounceBehavior(.basedOnSize)
        }
        .background(AppTheme.groupedCard)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(PorcelainChoicePanelColors.edge, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: PorcelainChoicePanelColors.shadow.opacity(0.035), radius: 3, y: 1)
        .shadow(color: PorcelainChoicePanelColors.shadow.opacity(0.10), radius: 12, y: 5)
    }

    private var rows: some View {
        VStack(spacing: 0) { content }.padding(4)
    }
}

struct PorcelainChoiceRow: View {
    let title: String
    let selected: Bool
    var minHeight: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PorcelainChoicePanelColors.check)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Text(title).font(.body).foregroundStyle(PorcelainChoicePanelColors.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PorcelainChoiceButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PorcelainChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            if configuration.isPressed {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(PorcelainChoicePanelColors.pressed)
            }
        }
    }
}
