import SwiftUI

struct SubtitlePictureInPicturePreferences: Codable, Equatable {
    enum DisplayMode: String, CaseIterable, Codable {
        case bilingual, original, translation

        var displayName: String {
            switch self {
            case .bilingual: return L10n.text("双语")
            case .original: return L10n.text("仅原文")
            case .translation: return L10n.text("仅译文")
            }
        }
    }

    enum Theme: String, CaseIterable, Codable {
        case black, white

        var displayName: String { self == .black ? L10n.text("深色") : L10n.text("浅色") }
    }

    enum Background: String, CaseIterable, Codable {
        case cover, solid

        var displayName: String { self == .cover ? L10n.text("作品图片") : L10n.text("纯色") }
    }

    enum Layout: String, CaseIterable, Codable {
        case small, medium, large

        var displayName: String {
            switch self {
            case .small: return L10n.text("小")
            case .medium: return L10n.text("中")
            case .large: return L10n.text("大")
            }
        }
    }

    static let fontSizeRange: ClosedRange<Double> = 16...38

    var mode: DisplayMode = .bilingual
    var fontSize: Double = 24
    var theme: Theme = .black
    var layout: Layout = .medium
    var background: Background = .cover

    init() {}

    private enum CodingKeys: String, CodingKey { case mode, fontSize, theme, layout, background }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? .bilingual
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 24
        theme = try values.decodeIfPresent(Theme.self, forKey: .theme) ?? .black
        layout = try values.decodeIfPresent(Layout.self, forKey: .layout) ?? .medium
        background = try values.decodeIfPresent(Background.self, forKey: .background) ?? .cover
    }

    /// Rendered content proportions only; iOS controls the actual PiP window dimensions.
    var frameSize: CGSize {
        switch layout {
        case .small: return CGSize(width: 720, height: 180)
        case .medium: return CGSize(width: 720, height: 300)
        case .large: return CGSize(width: 720, height: 480)
        }
    }
}

struct SubtitlePictureInPictureSheet: View {
    @EnvironmentObject private var pictureInPicture: AppPictureInPictureCoordinator

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Keep AVKit's actual source mounted while the settings scroll.
                preview.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
                settings
            }
            .appPageBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let message = pictureInPicture.message {
                    Text(message).font(.footnote).foregroundStyle(AppTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .accessibilityIdentifier("subtitlePiPMessage")
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("字幕浮窗"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { pictureInPicture.isSubtitleSheetPresented = false }
                }
            }
            .task { await pictureInPicture.prepareSubtitlePreview() }
            .onDisappear { pictureInPicture.finishSubtitlePreviewIfUnused() }
        }
        .appSettingsColorScheme()
    }

    private var settings: some View {
        Form {
            settingsSections.appListRows()
        }
        .scrollContentBackground(.hidden)
        .tint(AppTheme.optionalTint)
        // Fade only scrolling controls into the shared backdrop. The AVKit source
        // and its selected output colors remain intact above this boundary.
        .mask(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.156), location: 0.25),
                    .init(color: .black.opacity(0.5), location: 0.5),
                    .init(color: .black.opacity(0.844), location: 0.75),
                    .init(color: .black, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .frame(height: 20)
                Rectangle()
            }
        }
    }

    @ViewBuilder
    private var settingsSections: some View {
        Section("字幕显示") {
            Picker("显示内容", selection: $pictureInPicture.subtitleOptions.mode) {
                ForEach(SubtitlePictureInPicturePreferences.DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("subtitlePiPMode")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("字号")
                    Spacer()
                    Text(pictureInPicture.subtitleOptions.fontSize, format: .number.precision(.fractionLength(0)))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Slider(value: $pictureInPicture.subtitleOptions.fontSize,
                       in: SubtitlePictureInPicturePreferences.fontSizeRange, step: 1)
                    .accessibilityLabel("字幕字号")
                    .accessibilityIdentifier("subtitlePiPFont")
            }

            Picker("背景", selection: $pictureInPicture.subtitleOptions.background) {
                ForEach(SubtitlePictureInPicturePreferences.Background.allCases, id: \.self) { background in
                    Text(background.displayName).tag(background)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("subtitlePiPBackground")

            Picker("明暗", selection: $pictureInPicture.subtitleOptions.theme) {
                ForEach(SubtitlePictureInPicturePreferences.Theme.allCases, id: \.self) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("subtitlePiPTheme")

            Text("作品图片会模糊显示；个人音声使用创作者头像。没有图片时使用所选底色。")
                .font(.footnote).foregroundStyle(AppTheme.secondaryText)
        }

        Section {
            Picker("画面布局", selection: $pictureInPicture.subtitleOptions.layout) {
                ForEach(SubtitlePictureInPicturePreferences.Layout.allCases, id: \.self) { layout in
                    Text(layout.displayName).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("subtitlePiPLayout")
        } header: {
            Text("画面布局")
        } footer: {
            Text("按画面高度和字号显示前后字幕，突出当前句，字号不会自动缩小。小、中、大调整画面比例；实际浮窗大小和停靠由系统决定，可双指调整。")
        }

        Section {
            Text(pictureInPicture.pip.isActive ? L10n.text("字幕浮窗已开启") :
                    (pictureInPicture.pip.isStarting ? L10n.text("正在开启字幕浮窗…") :
                        (pictureInPicture.pip.isStopping ? L10n.text("正在关闭字幕浮窗…") : L10n.text("字幕浮窗未开启"))))
                .accessibilityIdentifier("subtitlePiPStatus")
            Button {
                // Keep the visible source attached while the asynchronous PiP start is pending.
                pictureInPicture.requestStartSubtitles()
            } label: {
                Label("开启字幕浮窗", systemImage: "pip.enter")
            }
            .accessibilityIdentifier("subtitlePiPStart")
            .disabled(pictureInPicture.pip.isActive || pictureInPicture.pip.isStarting || pictureInPicture.pip.isStopping)

            Button {
                pictureInPicture.stopSubtitles()
            } label: {
                Label("关闭字幕浮窗", systemImage: "pip.exit")
            }
            .accessibilityIdentifier("subtitlePiPStop")

        } footer: {
            Text("关闭浮窗不暂停音频；浮窗播放/暂停只控制字幕显示。")
        }
    }

    private var preview: some View {
        ZStack {
            if pictureInPicture.pip.configuredKind == .subtitles {
                SystemPictureInPictureSurface(controller: pictureInPicture.pip)
            } else if let frame = pictureInPicture.subtitleFallbackFrame {
                Image(uiImage: frame).resizable().scaledToFit()
            } else { Color.black }
        }
        .aspectRatio(pictureInPicture.subtitleOptions.frameSize, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("字幕浮窗预览")
        .accessibilityIdentifier("subtitlePiPPreview")
    }
}
