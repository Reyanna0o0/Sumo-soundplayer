import SwiftUI

/// 在同一页选择字幕来源和它的版本；恢复历史时始终保留原始记录。
struct SubtitleVersionSheet: View {
    @ObservedObject var editor: SubtitleEditorController
    let sources: [SubtitleTrackRecord]
    let onSelectSource: (SubtitleTrackRecord) -> String?
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            AppList {
                Section("字幕来源") {
                    if sources.isEmpty {
                        Text("还没有字幕来源").foregroundStyle(AppTheme.secondaryText)
                    }
                    ForEach(sources) { source in
                        Button {
                            errorMessage = onSelectSource(source)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.displayLabel)
                                    Text("\(source.kind.displayName) · \(source.versionCount) 个版本")
                                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer()
                                if source.id == editor.subtitleTrackID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("subtitleSource-\(source.id)")
                        .accessibilityValue(source.id == editor.subtitleTrackID ? L10n.text("当前来源") : "")
                    }
                    ForEach(editor.pinnedVersions) { version in
                        Button {
                            if editor.restorePinnedVersion(version) {
                                onChange()
                                dismiss()
                            } else { errorMessage = editor.message ?? L10n.text("未能切换字幕版本，请重试。") }
                        } label: {
                            versionRow(version, sourceLabel: sources.first(where: { $0.id == version.subtitleTrackID })?.displayLabel)
                        }
                        .accessibilityIdentifier("subtitlePinnedVersion-\(version.id)")
                        .contextMenu { pinAction(version) }
                        .accessibilityAction(named: L10n.text("取消固定")) { togglePin(version) }
                    }
                }

                Section {
                    if editor.versions.isEmpty {
                        Text("还没有版本记录").foregroundStyle(AppTheme.secondaryText)
                    } else if editor.versions.allSatisfy(\.isPinned) {
                        Text("此来源的版本均已固定").foregroundStyle(AppTheme.secondaryText)
                    } else {
                        ForEach(editor.versions.filter { !$0.isPinned }) { version in
                            Button {
                                if editor.switchVersion(version) {
                                    onChange()
                                    dismiss()
                                } else { errorMessage = editor.message ?? L10n.text("未能切换字幕版本，请重试。") }
                            } label: {
                                versionRow(version)
                            }
                            .accessibilityIdentifier("subtitleVersion-\(version.versionNo)")
                            .contextMenu { pinAction(version) }
                            .accessibilityAction(named: L10n.text("固定版本")) { togglePin(version) }
                        }
                    }
                } header: {
                    Text("所选来源的版本")
                } footer: {
                    Text("选择历史版本会保存一份新的恢复版本。长按可固定或取消固定；固定版本显示在字幕来源中，不会被历史清理移除。")
                }

                Section {
                    Button {
                        if editor.revertToBaseline() {
                            onChange()
                            dismiss()
                        } else { errorMessage = editor.message ?? L10n.text("未能恢复原始字幕，请重试。") }
                    } label: {
                        Label("恢复原始版本", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!editor.versions.contains(where: \.isBaseline))
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("字幕版本"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("字幕提示", isPresented: Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .appSettingsColorScheme()
    }

    private func pinAction(_ version: SubtitleVersionRecord) -> some View {
        Button { togglePin(version) } label: {
            Label(version.isPinned ? L10n.text("取消固定") : L10n.text("固定版本"),
                  systemImage: version.isPinned ? "pin.slash" : "pin")
        }
        .accessibilityIdentifier("\(version.isPinned ? "subtitleUnpinVersion" : "subtitlePinVersion")-\(version.id)")
    }

    private func togglePin(_ version: SubtitleVersionRecord) {
        if editor.setVersionPinned(version, isPinned: !version.isPinned) {
            UIAccessibility.post(notification: .announcement, argument: editor.message)
        } else {
            errorMessage = editor.message ?? L10n.text("版本已变更，请重新打开字幕版本。")
        }
    }

    private func versionRow(_ version: SubtitleVersionRecord, sourceLabel: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                if let sourceLabel {
                    Text(sourceLabel).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                }
                HStack(spacing: 6) {
                    if version.isPinned {
                        Image(systemName: "pin.fill").foregroundStyle(AppTheme.iconTint)
                            .accessibilityLabel("已固定")
                    }
                    Text("v\(version.versionNo)").font(.subheadline.weight(.medium))
                    if version.isBaseline {
                        Text("原始").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.18), in: Capsule())
                    }
                    if version.id == editor.activeVersionID {
                        Text("当前").font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(AppTheme.accent.opacity(0.2), in: Capsule())
                    }
                }
                if !version.note.isEmpty {
                    Text(version.note).font(.caption2).foregroundStyle(AppTheme.secondaryText).lineLimit(2)
                }
                Text("\(version.cueCount) 句 · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            if version.id == editor.activeVersionID {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
    }
}
