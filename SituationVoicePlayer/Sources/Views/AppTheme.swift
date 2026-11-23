import Observation
import SwiftUI
import UIKit

enum AppPalette: String, CaseIterable, Identifiable {
    case native, porcelain, graphite, purple

    var id: Self { self }
    var name: String {
        switch self {
        case .native: L10n.text("原生")
        case .porcelain: L10n.text("米白")
        case .graphite: L10n.text("浅黑色")
        case .purple: L10n.text("紫色")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .native: nil
        case .porcelain: .light
        case .graphite, .purple: .dark
        }
    }
}

@Observable
final class AppearanceSelection {
    static let shared = AppearanceSelection()
    private static let key = "appAppearancePalette"
    static let didChangeNotification = Notification.Name("AppearanceSelection.didChange")

    var palette: AppPalette {
        didSet {
            UserDefaults.standard.set(palette.rawValue, forKey: Self.key)
            if palette != oldValue {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    private init() {
        palette = UserDefaults.standard.string(forKey: Self.key).flatMap(AppPalette.init(rawValue:)) ?? .porcelain
    }
}

enum AppTheme {
    static var isNative: Bool { AppearanceSelection.shared.palette == .native }
    static var isPorcelain: Bool { AppearanceSelection.shared.palette == .porcelain }
    static var isGraphite: Bool { AppearanceSelection.shared.palette == .graphite }
    static var isPurple: Bool { AppearanceSelection.shared.palette == .purple }
    static var usesCustomPalette: Bool { !isNative }
    static var usesDarkPalette: Bool { isGraphite || isPurple }

    static func usesChoicePanels(in scheme: ColorScheme) -> Bool {
        usesDarkPalette || (isPorcelain && scheme == .light)
    }

    static func painted(_ native: Color, _ themed: Color) -> Color {
        isNative ? native : themed
    }

    private static func color(_ porcelain: UInt32, graphite: UInt32, purple: UInt32, native: Color) -> Color {
        switch AppearanceSelection.shared.palette {
        case .native: native
        case .porcelain: rgb(porcelain)
        case .graphite: rgb(graphite)
        case .purple: rgb(purple)
        }
    }

    static var background: Color { color(0xFAF8F2, graphite: 0x27282B, purple: 0x1D224A, native: Color(uiColor: .systemGroupedBackground)) }
    static var porcelainBackground: Color { background }
    static var card: Color { color(0xFFFDF8, graphite: 0x353639, purple: 0x2D2A45, native: Color(uiColor: .secondarySystemGroupedBackground)) }
    static var groupedCard: Color { isPorcelain ? rgb(0xFFFEFC) : card }
    static var libraryHeaderSurface: Color { usesDarkPalette ? background : card }
    static var surface: Color { color(0xECE9DE, graphite: 0x2F3033, purple: 0x373249, native: Color(uiColor: .secondarySystemBackground)) }
    static var ink: Color { color(0x292924, graphite: 0xF1EDEA, purple: 0xF6F3FA, native: .primary) }
    static var secondary: Color { color(0x666456, graphite: 0xC5BEBB, purple: 0xD4CFE0, native: .secondary) }
    static var tertiary: Color { color(0x666456, graphite: 0xAAA4A2, purple: 0xBEB8CB, native: Color(uiColor: .tertiaryLabel)) }
    static var emphasisInk: Color { color(0xA52332, graphite: 0xEDEBE6, purple: 0xFFFFFF, native: .accentColor) }
    static var iconTint: Color { color(0x9A322A, graphite: 0xDAD7D0, purple: 0xD8BDF3, native: .accentColor) }
    static var emphasisIcon: Color { usesDarkPalette ? iconTint : emphasisInk }
    static var optionalTint: Color? { usesCustomPalette ? iconTint : nil }
    static var accent: Color { emphasisInk }
    static var onAccent: Color { usesDarkPalette ? background : .white }
    static var separator: Color { color(0xD9D5C8, graphite: 0x4B4A4C, purple: 0x50485F, native: Color(uiColor: .separator)) }
    static var titleInk: Color { headingInk() }
    static var libraryTitleInk: Color { headingInk() }
    static var statisticsSummaryGradient: LinearGradient {
        let start = color(0xF4DFD9, graphite: 0x4A494B, purple: 0x574262, native: Color.accentColor.opacity(0.13))
        let end = color(0xFFF7F2, graphite: 0x333538, purple: 0x373552, native: Color(uiColor: .secondarySystemGroupedBackground))
        return LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var emptyListeningHour: Color { color(0xF8E9E4, graphite: 0x414246, purple: 0x423D55, native: Color.secondary.opacity(0.12)) }
    static var peakListeningHour: Color { color(0xA52332, graphite: 0xDFD9CD, purple: 0x9D83BA, native: .accentColor) }
    static var shadow: Color { color(0x695443, graphite: 0x0E0E10, purple: 0x090916, native: .black) }

    static func headingInk(previous: Color = .primary) -> Color {
        isNative ? previous : emphasisInk
    }

    // Both surfaces carry the light plum farther down than the original playlist.
    // The audio player has its own lower-left origin and slightly lighter stops.
    private static func purpleGradient(_ colors: (UInt32, UInt32, UInt32),
                                       from: UnitPoint, to: UnitPoint) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: rgb(colors.0), location: 0.12),
            .init(color: rgb(colors.1), location: 0.58),
            .init(color: rgb(colors.2), location: 1)
        ], startPoint: from, endPoint: to)
    }
    static var purpleBackdrop: LinearGradient {
        purpleGradient((0x7D4F87, 0x1D224A, 0x080B18), from: .topTrailing, to: .bottomLeading)
    }
    static var purplePlayerBackdrop: LinearGradient {
        purpleGradient((0x855A8F, 0x2C3057, 0x181A28), from: .bottomLeading, to: .topTrailing)
    }
    static var purplePlayerButton: Color { rgb(0x302044) }
    static var purpleMiniSurface: LinearGradient {
        LinearGradient(colors: [rgb(0x3D3866), rgb(0x5C4B80)], startPoint: .leading, endPoint: .trailing)
    }
    static var purplePlaybackIndicator: Color { rgb(0xE7E2F2) }
    static var purpleTabSurface: Color { rgb(0x201E32) }

    static func trendBarStyle(selected: Bool) -> AnyShapeStyle {
        if isPurple {
            return selected ? AnyShapeStyle(rgb(0xF3E5FF)) : AnyShapeStyle(LinearGradient(
                colors: [rgb(0xC9B5E0), rgb(0x9684A9)], startPoint: .top, endPoint: .bottom))
        }
        if isGraphite {
            return selected ? AnyShapeStyle(titleInk) : AnyShapeStyle(LinearGradient(
                colors: [rgb(0xBDB8AE), rgb(0x97948C)], startPoint: .top, endPoint: .bottom))
        }
        let ink = painted(.blue, accent)
        return AnyShapeStyle((selected ? ink : ink.opacity(0.72)).gradient)
    }

    static func rgb(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
}

extension EnvironmentValues {
    @Entry var purpleViewport: CGRect = .zero
}

/// Sample the same window-sized gradient behind the navbar, scrolling content and mini player.
/// A scroll view may occupy only part of the window or be inside a sheet.
struct PurplePageBackdrop: View {
    @Environment(\.purpleViewport) private var viewport

    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let bounds = viewport.isEmpty ? frame : viewport
            AppTheme.purpleBackdrop
                .frame(width: bounds.width, height: bounds.height)
                .offset(x: bounds.minX - frame.minX, y: bounds.minY - frame.minY)
        }
        .clipped()
        .ignoresSafeArea(.container)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AppContentTheme: ViewModifier {
    func body(content: Content) -> some View { content.tint(AppTheme.optionalTint) }
}

extension EnvironmentValues {
    /// 主界面的明暗独立传入弹层，避免原生外观继承阅读页强制的深色。
    @Entry var appAppearanceColorScheme: ColorScheme = .light
}

private struct AppSettingsColorScheme: ViewModifier {
    @Environment(\.appAppearanceColorScheme) private var appColorScheme

    func body(content: Content) -> some View {
        content.preferredColorScheme(AppearanceSelection.shared.palette.preferredColorScheme ?? appColorScheme)
    }
}

struct AppForm<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { Form { content().appListRows() }.appListSurface() }
}

struct AppList<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        List { content().appListRows() }.appListSurface()
            .frame(maxWidth: 860).frame(maxWidth: .infinity)
    }
}

/// 原生 List 可能保留上一轮背景配置；常驻 UIKit 背景直接跟随最新皮肤，
/// 不依赖行重建，也不让稍晚到达的 SwiftUI 更新回填旧颜色。
private struct AppListRowBackdrop: UIViewRepresentable {
    func makeUIView(context: Context) -> PaletteBackgroundView { PaletteBackgroundView() }
    func updateUIView(_ view: PaletteBackgroundView, context: Context) { view.applyCurrentPalette() }

    final class PaletteBackgroundView: UIView {
        private var paletteObserver: NSObjectProtocol?

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            paletteObserver = NotificationCenter.default.addObserver(
                forName: AppearanceSelection.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyCurrentPalette() }
            }
            applyCurrentPalette()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit {
            if let paletteObserver { NotificationCenter.default.removeObserver(paletteObserver) }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyCurrentPalette()
        }

        func applyCurrentPalette() {
            // 原生色保留动态 UIColor；不按旧环境预先解析成固定 CGColor。
            // 每次都读当前选择，通知和 updateUIView 的先后顺序不影响结果。
            let color = AppTheme.isNative ? UIColor.secondarySystemGroupedBackground : UIColor(AppTheme.groupedCard)
            UIView.performWithoutAnimation { backgroundColor = color }
        }
    }
}

private struct AppListRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            // 原生和自定义皮肤共享同一个背景宿主，避免 nil/自定义配置反复装卸。
            .listRowBackground(AppListRowBackdrop())
            // 分隔线沿用系统动态颜色；圆角与分组裁切仍由原生 List 负责。
    }
}

private struct AppListSurfaceStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(AppTheme.usesCustomPalette ? .hidden : .automatic)
            .appPageBackground(AppTheme.painted(.clear, AppTheme.background))
            .tint(AppTheme.optionalTint)
    }
}

extension View {
    func appSettingsColorScheme() -> some View { modifier(AppSettingsColorScheme()) }

    func appPageBackground(_ fallback: Color = AppTheme.background) -> some View {
        background {
            if AppTheme.isPurple { PurplePageBackdrop() }
            else { fallback.ignoresSafeArea() }
        }
    }

    func porcelainSurface() -> some View {
        tint(AppTheme.optionalTint)
    }

    func porcelainSheet<Sheet: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Sheet) -> some View {
        sheet(isPresented: isPresented) { content().appSheetSurface() }
    }

    func porcelainSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        sheet(item: item) { item in content(item).appSheetSurface() }
    }

    @ViewBuilder private func appSheetSurface() -> some View {
        if AppTheme.isPurple {
            presentationBackground(AppTheme.purpleBackdrop).porcelainSurface()
        } else if AppTheme.usesCustomPalette {
            presentationBackground(AppTheme.porcelainBackground).porcelainSurface()
        } else {
            self
        }
    }

    func appListRows() -> some View {
        modifier(AppListRowStyle())
    }

    func appListSurface() -> some View {
        modifier(AppListSurfaceStyle())
    }

    func appNavigationColors(contentTitle: Bool = false) -> some View {
        background {
            NavigationTitleInk(contentTitle: contentTitle, palette: AppearanceSelection.shared.palette)
                .frame(width: 0, height: 0).accessibilityHidden(true).allowsHitTesting(false)
        }
    }
}

private struct NavigationTitleInk: UIViewControllerRepresentable {
    let contentTitle: Bool
    let palette: AppPalette

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.active = palette != .native
        controller.large = UIColor(cgColor: AppTheme.titleInk.resolve(in: context.environment).cgColor)
        let inline = contentTitle ? AppTheme.ink : AppTheme.headingInk(previous: AppTheme.ink)
        controller.inline = UIColor(cgColor: inline.resolve(in: context.environment).cgColor)
        controller.apply()
    }

    final class Probe: UIViewController {
        // A navigation stack shares its bar across pushed pages. Keep the native
        // colors per actual bar, including absence of a color attribute.
        private final class NativeTitleColors {
            let inline: Any?
            let large: Any?
            init(_ bar: UINavigationBar) {
                inline = bar.titleTextAttributes?[.foregroundColor]
                large = bar.largeTitleTextAttributes?[.foregroundColor]
            }
        }

        private static let nativeColors = NSMapTable<UINavigationBar, NativeTitleColors>.weakToStrongObjects()
        var active = false
        var large = UIColor.label
        var inline = UIColor.label

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func apply() {
            guard let bar = navigationController?.navigationBar else { return }
            var largeAttributes = bar.largeTitleTextAttributes ?? [:]
            var inlineAttributes = bar.titleTextAttributes ?? [:]
            if active {
                if Self.nativeColors.object(forKey: bar) == nil {
                    Self.nativeColors.setObject(NativeTitleColors(bar), forKey: bar)
                }
                largeAttributes[.foregroundColor] = large
                inlineAttributes[.foregroundColor] = inline
            } else {
                guard let native = Self.nativeColors.object(forKey: bar) else { return }
                largeAttributes[.foregroundColor] = native.large
                inlineAttributes[.foregroundColor] = native.inline
                Self.nativeColors.removeObject(forKey: bar)
            }
            bar.largeTitleTextAttributes = largeAttributes.isEmpty ? nil : largeAttributes
            bar.titleTextAttributes = inlineAttributes.isEmpty ? nil : inlineAttributes
        }
    }
}
