import SwiftUI

/// 统计设置：按库启用、合并/分开展示、组件开关与长按拖动排序、月度回顾入口。
struct StatisticsSettingsView: View {
    @StateObject private var preferences = StatisticsPreferences.shared
    @State private var reordering = false

    var body: some View {
        AppForm {
            Section {
                Toggle(MediaLibraryKind.personal.displayName, isOn: personalBinding)
                    .accessibilityIdentifier("statsPersonalToggle")
                Toggle(MediaLibraryKind.collection.displayName, isOn: collectionBinding)
                    .accessibilityIdentifier("statsCollectionToggle")
            } header: {
                Text("统计来源")
            } footer: {
                Text("关闭后只影响统计页的显示，不会删除任何记录，也不会停止继续记录播放。")
            }

            if preferences.bothEnabled {
                Section {
                    Picker("展示方式", selection: displayModeBinding) {
                        ForEach(StatisticsDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("statsDisplayMode")
                } header: {
                    Text("两个库的统计")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("合并：个人作品按创作者计入社团/声优排行，总时长不会重复计算；未归属的独立片段计入合并总数。")
                        Text("分开：分别查看个人音声与社团作品。")
                    }
                }
            }

            Section {
                ForEach(preferences.moduleOrder) { module in
                    HStack {
                        Label(module.displayName, systemImage: module.iconName)
                        Spacer()
                        if reordering || preferences.isPinned(module) {
                            Text(preferences.isPinned(module) ? L10n.text("常驻") : "")
                                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                        } else {
                            Toggle(module.displayName, isOn: enabledBinding(module))
                                .labelsHidden()
                                .accessibilityLabel(module.displayName)
                                .accessibilityIdentifier("statsWidget-\(module.rawValue)")
                        }
                    }
                }
                .onMove(perform: moveModules)
            } header: {
                HStack {
                    Text("统计组件")
                    Spacer()
                    Button(reordering ? L10n.text("完成") : L10n.text("排序")) { reordering.toggle() }
                        .font(.subheadline)
                        .accessibilityIdentifier("statsReorderWidgets")
                }
            } footer: {
                Text("统计页可长按组件拖到其他组件调整顺序；点「排序」后也可在此调整。")
            }

            Section {
                Toggle("月度回顾入口", isOn: monthlyBinding)
                    .accessibilityIdentifier("statsMonthlyToggle")
            } footer: {
                Text("关闭回顾入口只是隐藏统计页上的按钮，报告数据与分享不受影响。")
            }

            Section {
                Button("恢复默认") { preferences.resetAll() }
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("statsResetDefaults")
            } footer: {
                Text("分享报告会标注当前统计范围；恢复默认只重设显示选项。")
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("统计"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(reordering ? .active : .inactive))
        .accessibilityIdentifier("statisticsSettings")
    }

    private var personalBinding: Binding<Bool> {
        Binding(get: { preferences.personalEnabled },
                set: { preferences.setEnabled($0, for: .personal) })
    }

    private var collectionBinding: Binding<Bool> {
        Binding(get: { preferences.collectionEnabled },
                set: { preferences.setEnabled($0, for: .collection) })
    }

    private var displayModeBinding: Binding<StatisticsDisplayMode> {
        Binding(get: { preferences.displayMode }, set: { preferences.setDisplayMode($0) })
    }

    private var monthlyBinding: Binding<Bool> {
        Binding(get: { preferences.monthlyReviewEnabled },
                set: { preferences.setMonthlyReviewEnabled($0) })
    }

    private var annualBinding: Binding<Bool> {
        Binding(get: { preferences.annualReviewEnabled },
                set: { preferences.setAnnualReviewEnabled($0) })
    }

    private var exportScopeBinding: Binding<Bool> {
        Binding(get: { UserDefaults.standard.bool(forKey: StatisticsDefaultsKey.exportScopeLabel) },
                set: { UserDefaults.standard.set($0, forKey: StatisticsDefaultsKey.exportScopeLabel) })
    }

    private func enabledBinding(_ module: StatisticsModule) -> Binding<Bool> {
        Binding(get: { preferences.isEnabled(module) },
                set: { preferences.setEnabled($0, for: module) })
    }

    private func moveModules(from source: IndexSet, to destination: Int) {
        preferences.move(from: source, to: destination)
    }
}

#Preview {
    NavigationStack { StatisticsSettingsView() }
}
