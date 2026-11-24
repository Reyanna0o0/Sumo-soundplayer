import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isSeeding = false
    @ObservedObject private var speakerProtection = SpeakerProtection.shared
    @AppStorage(CoverPrivacy.settingKey) private var privacyEnabled = false
    @AppStorage(CallInterfacePreferences.realisticLabelsKey) private var realisticCallLabels = false
    @State private var callProfilePresentation: CallProfilePresentation?
    @State private var callProfileError: String?
    @State private var spatialCacheBytes: Int64 = 0
    @State private var clearingSpatialCache = false
    @State private var spatialCacheError: String?
    @State private var subtitleHistorySummary: SubtitleHistoryCleanupSummary?
    @State private var loadingSubtitleHistory = false
    @State private var clearingSubtitleHistory = false
    @State private var confirmSubtitleHistoryCleanup = false
    @State private var subtitleHistoryMessage: String?
    @State private var subtitleHistoryError: String?

    private struct CallProfilePresentation: Identifiable {
        let id = UUID()
        let profile: CallProfile
    }

    var body: some View {
        @Bindable var appearance = AppearanceSelection.shared
        NavigationStack {
            AppList {
                Section {
                    LanguageSettingsPicker().environment(\.dynamicTypeSize, dynamicTypeSize)
                } footer: {
                    Text("语言已内置，无需下载。仅更改界面文字，不改动作品、台本和字幕。").transformEnvironment(\.font) { if dynamicTypeSize.isAccessibilitySize { $0 = .footnote } }.environment(\.dynamicTypeSize, dynamicTypeSize)
                }
                Section {
                    AppearancePalettePicker(selection: $appearance.palette).environment(\.dynamicTypeSize, dynamicTypeSize)
                } header: { Text("外观").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                Section {
                    NavigationLink {
                        LaunchSettingsView().environment(\.dynamicTypeSize, dynamicTypeSize)
                    } label: { Label("启动与图标", systemImage: "sparkles").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityIdentifier("launchSettingsEntry")
                }
                Section {
                    Toggle("防偷窥", isOn: $privacyEnabled)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityIdentifier("coverPrivacyToggle")
                } footer: {
                    Text("浏览作品时模糊封面，播放页显示原图。锁屏和控制中心使用模糊封面，音轨显示为「\(CoverPrivacy.publicTitle)」。").transformEnvironment(\.font) { if dynamicTypeSize.isAccessibilitySize { $0 = .footnote } }.environment(\.dynamicTypeSize, dynamicTypeSize)
                }

                Section {
                    Toggle("外放保护", isOn: $speakerProtection.isEnabled)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityIdentifier("speakerProtectionToggle")
                } footer: {
                    Text("使用设备扬声器时默认静音。播放时调节系统音量可允许本次外放，连接耳机也会解除静音。重新开始播放或切回扬声器时再次保护。解除静音不会自动播放已暂停的内容。")
                        .transformEnvironment(\.font) { if dynamicTypeSize.isAccessibilitySize { $0 = .footnote } }
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                }

                Section {
                    NavigationLink {
                        StatisticsSettingsView().environment(\.dynamicTypeSize, dynamicTypeSize)
                    } label: {
                        Label("统计显示", systemImage: "chart.bar.xaxis").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityIdentifier("statisticsSettingsEntry")
                } header: { Text("统计").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }

                Section {
                    Toggle("完全模拟通话按键名称", isOn: $realisticCallLabels)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityIdentifier("realisticCallLabels")
                    Button {
                        do {
                            callProfilePresentation = CallProfilePresentation(
                                profile: try store.callProfile(ownerKind: .localUser, id: 0)
                            )
                        } catch { callProfileError = error.localizedDescription }
                    } label: { Label("我的头像", systemImage: "person.crop.rectangle").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }
                    .accessibilityIdentifier("myCallDisplayEntry")
                } header: { Text("通话").dynamicTypeSize(...DynamicTypeSize.xxxLarge) } footer: {
                    Text("关闭时显示暂停、继续和我的头像；开启后显示麦克风、打开摄像头等通话名称。实际功能仍是播放控制和显示已选图片。").transformEnvironment(\.font) { if dynamicTypeSize.isAccessibilitySize { $0 = .footnote } }.environment(\.dynamicTypeSize, dynamicTypeSize)
                }

                Section {
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(subtitleHistorySummary.map { L10n.text("\($0.versionCount) 个版本") } ?? "—")
                            Text(subtitleHistorySummary.map { L10n.text("文本约占 \(cacheSize($0.estimatedContentBytes))") } ?? "—")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                .accessibilityIdentifier("subtitleHistoryCacheSize")
                        }
                        .multilineTextAlignment(.trailing)
                    } label: { Text("字幕历史缓存") }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityIdentifier("subtitleHistoryCacheCount")
                    Button {
                        subtitleHistoryMessage = nil
                        Task {
                            await refreshSubtitleHistory()
                            if let count = subtitleHistorySummary?.versionCount, count > 0 { confirmSubtitleHistoryCleanup = true }
                        }
                    } label: {
                        HStack {
                            Text("清理字幕历史缓存").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            Spacer()
                            if clearingSubtitleHistory || loadingSubtitleHistory { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(clearingSubtitleHistory || loadingSubtitleHistory || subtitleHistorySummary == nil || subtitleHistorySummary?.versionCount == 0)
                    .accessibilityIdentifier("clearSubtitleHistory")
                    if let subtitleHistoryMessage {
                        Text(subtitleHistoryMessage).font(.footnote).foregroundStyle(AppTheme.secondaryText).environment(\.dynamicTypeSize, dynamicTypeSize)
                            .accessibilityIdentifier("subtitleHistoryCleanupResult")
                    }
                    LabeledContent("图片空间效果", value: cacheSize(spatialCacheBytes)).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityIdentifier("spatialCacheSize")
                    Button("清理空间效果缓存") {
                        clearingSpatialCache = true
                        Task {
                            do { try await CallSpatialDepth.shared.clearCache() }
                            catch { spatialCacheError = L10n.text("暂时无法清理空间效果缓存：\(error.localizedDescription)") }
                            spatialCacheBytes = await CallSpatialDepth.shared.cacheBytes()
                            clearingSpatialCache = false
                        }
                    }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .disabled(clearingSpatialCache || spatialCacheBytes == 0)
                        .accessibilityIdentifier("clearCallSpatialCache")
                } header: { Text("App 缓存").dynamicTypeSize(...DynamicTypeSize.xxxLarge) } footer: {
                    Text("字幕容量按可清理版本的文本内容估算，清理后数据库空间可供后续编辑复用。原始、当前、固定及草稿引用的版本保留；图片原图和取景设置保留。").transformEnvironment(\.font) { if dynamicTypeSize.isAccessibilitySize { $0 = .footnote } }.environment(\.dynamicTypeSize, dynamicTypeSize)
                }
                .task { await refreshSubtitleHistory() }
                .task { spatialCacheBytes = await CallSpatialDepth.shared.cacheBytes() }

                #if DEBUG
                Section {
                    Button {
                        Task { await seedSampleLibrary() }
                    } label: {
                        HStack {
                            Label("生成示例库（测试用）", systemImage: "wand.and.stars")
                            Spacer()
                            if isSeeding { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isSeeding)
                } header: {
                    Text("真机测试")
                } footer: {
                    Text("会在 App 沙盒里生成一个示例作品（含正片/特典/语音消息/闲聊、封面、台本），并自动扫描入库。用于没有音乐文件时验证播放。")
                }

                Section("开发") {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("诊断日志", systemImage: "doc.text.magnifyingglass")
                    }
                    NavigationLink {
                        CoreCheckView()
                    } label: {
                        Label("内核自检", systemImage: "checkmark.seal")
                    }
                }
                #endif

                Section {
                    LabeledContent("应用名称", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "—").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    LabeledContent("版本", value: appVersion).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("图片空间效果：Depth Anything V2 Small").font(.headline)
                                Text("Lihe Yang 等作者；Core ML 转换模型由 Apple 发布，Apache License 2.0。图片仅在本机处理。")
                                Link("模型来源与说明", destination: URL(string: "https://huggingface.co/apple/coreml-depth-anything-v2-small")!)
                                Text(Bundle.main.url(forResource: "DepthAnything-LICENSE", withExtension: "txt")
                                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Apache License 2.0")
                                    .font(.caption).textSelection(.enabled)
                                Text("MP3 编码使用 LAME 4.0").font(.headline)
                                Link("LAME 官方网站", destination: URL(string: "https://lame.sourceforge.io")!)
                                Text("GNU Library GPL v2 或后续版本。完整源代码、构建配置和许可随项目保留。")
                                Text(Bundle.main.url(forResource: "LAME-COPYING", withExtension: "txt")
                                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? L10n.text("许可证包含在项目 ThirdParty/Lame/lame-4.0/COPYING。"))
                                    .font(.caption).textSelection(.enabled)
                                Text("ZIP 解压：ZIPFoundation").font(.headline)
                                Link("ZIPFoundation 项目", destination: URL(string: "https://github.com/weichsel/ZIPFoundation")!)
                                Text(Bundle.main.url(forResource: "ZIPFoundation-LICENSE", withExtension: "txt")
                                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "MIT License")
                                    .font(.caption).textSelection(.enabled)
                                Text("AVI 兼容：FFmpeg").font(.headline)
                                Link("FFmpeg 项目与许可", destination: URL(string: "https://ffmpeg.org/legal.html")!)
                                Text("使用 FFmpeg 8.0.1 的精简本地文件组件。源码版本、构建脚本与许可随项目保留。")
                                Text(Bundle.main.url(forResource: "FFmpeg-LICENSE", withExtension: "txt")
                                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "GNU Lesser General Public License 2.1 or later")
                                    .font(.caption).textSelection(.enabled)
                            }.padding()
                        }.appPageBackground(AppTheme.painted(.clear, AppTheme.background)).appNavigationColors().navigationTitle(L10n.text("开源许可"))
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                    } label: { Text("开源许可") }
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                } header: { Text("关于").dynamicTypeSize(...DynamicTypeSize.xxxLarge) }

                #if DEBUG
                Section {
                    Text("这是自用版本，界面会随着开发逐步补齐。")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondary)
                }
                #endif
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .modifier(ScrollContentEdges.topOnly)
            .appPageBackground(AppTheme.painted(Color(uiColor: .systemGroupedBackground), AppTheme.background))
            .appNavigationColors().navigationTitle(L10n.text("设置"))
            .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .automatic)
            .toolbar {
                if dynamicTypeSize.isAccessibilitySize {
                    ToolbarItem(placement: .principal) {
                        Text("设置").font(.headline).foregroundStyle(AppTheme.ink)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .porcelainSheet(item: $callProfilePresentation) { presentation in
                CallProfileEditorSheet(title: L10n.text("我的头像"), ownerKind: .localUser, profile: presentation.profile) {
                    try store.saveCallProfile($0, ownerKind: .localUser, id: 0)
                }.environment(\.dynamicTypeSize, dynamicTypeSize)
            }
            .alert("无法读取通话资料", isPresented: Binding(get: { callProfileError != nil }, set: { if !$0 { callProfileError = nil } })) {
                Button("确定") { callProfileError = nil }
            } message: { Text(callProfileError ?? "") }
            .alert("清理字幕历史缓存？", isPresented: $confirmSubtitleHistoryCleanup) {
                Button("取消", role: .cancel) {}
                Button("清理旧记录", role: .destructive) { clearSubtitleHistory() }
                    .accessibilityIdentifier("subtitleHistoryCleanupConfirm")
            } message: {
                Text(L10n.text("将清理 \(subtitleHistorySummary?.versionCount ?? 0) 个未固定的旧版本，清理后无法恢复这些历史记录。原始、当前、固定及未完成编辑引用的版本均保留。"))
            }
            .alert("未能清理字幕历史", isPresented: Binding(get: { subtitleHistoryError != nil },
                set: { if !$0 { subtitleHistoryError = nil } })) {
                Button("好") { subtitleHistoryError = nil }
            } message: { Text(subtitleHistoryError ?? "") }
            .alert("未能清理图片缓存", isPresented: Binding(get: { spatialCacheError != nil },
                set: { if !$0 { spatialCacheError = nil } })) {
                Button("好") { spatialCacheError = nil }
            } message: { Text(spatialCacheError ?? "") }
        }
    }

    @MainActor private func refreshSubtitleHistory() async {
        guard !loadingSubtitleHistory, !clearingSubtitleHistory else { return }
        loadingSubtitleHistory = true
        defer { loadingSubtitleHistory = false }
        do { subtitleHistorySummary = try await store.subtitleHistoryCache() }
        catch {
            subtitleHistorySummary = nil
            subtitleHistoryError = L10n.text("无法读取字幕历史或未完成的编辑，已停止清理：\(error.localizedDescription)")
        }
    }

    private func clearSubtitleHistory() {
        guard !clearingSubtitleHistory else { return }
        clearingSubtitleHistory = true
        Task {
            do {
                let cleared = try await store.subtitleHistoryCache(clear: true)
                subtitleHistoryMessage = L10n.text("已清理 \(cleared.versionCount) 个旧版本")
                // 删除已提交，后续计数失败不能把它误报为清理失败。
                subtitleHistorySummary = try? await store.subtitleHistoryCache()
            } catch {
                subtitleHistoryError = L10n.text("清理未完成：\(error.localizedDescription)")
            }
            clearingSubtitleHistory = false
        }
    }

    private func cacheSize(_ bytes: Int64) -> String {
        ByteCountFormatStyle(style: .file, spellsOutZero: false,
            locale: AppLanguageSelection.shared.locale).format(bytes)
    }

    #if DEBUG
    private func seedSampleLibrary() async {
        isSeeding = true
        defer { isSeeding = false }
        do {
            let root = try DebugSeed.makeSampleLibrary()
            await store.importFolder(url: root)
        } catch {
            store.reportError("生成示例库失败：\(error.localizedDescription)")
        }
    }
    #endif

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// List 的内容闭包可能缓存已取出的颜色；由选项本身观察皮肤，更新当前值和箭头。
private struct LanguageSettingsPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var language = AppLanguageSelection.shared
        @Bindable var appearance = AppearanceSelection.shared
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    Picker("App 语言", selection: $language.language) {
                        ForEach(AppLanguage.allCases) { choice in Text(verbatim: choice.name).tag(choice) }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("App 语言")
                        Text(verbatim: language.language.name).foregroundStyle(AppTheme.secondaryText)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
            } else {
                Picker("App 语言", selection: $language.language) {
                    ForEach(AppLanguage.allCases) { choice in Text(verbatim: choice.name).tag(choice) }
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .tint(AppTheme.ink)
        // 原生菜单选择器会缓存已解析的 tint。只重建这个无草稿控件，
        // 绑定的语言选择、外层列表滚动和导航状态均留在原处。
        .id(appearance.palette)
        .accessibilityIdentifier("appLanguagePicker")
    }
}

#Preview {
    SettingsView()
}
