import SwiftUI

/// 导入前的选择面板：这个文件夹算"一个作品"还是"一堆作品"。
///
/// 为什么需要手动选：自动判断在真实目录上会猜错。
/// 例如一个特典目录里同时有 `wav/` 和 `SEあり/` 两个子目录，
/// 自动规则会把它拆成两个作品（名字变成 "wav" 和 "SEあり"），完全没法看。
struct ImportOptionsSheet: View {
    let folderURL: URL
    let store: LibraryStore

    @Environment(\.dismiss) private var dismiss

    @State private var grouping: ScanOptions.Grouping = .singleWork
    @State private var preview: LibraryStore.ImportPreview?
    @State private var isLoading = false

    /// 用户确认后的回调
    let onConfirm: (ScanOptions.Grouping) -> Void

    private let modes: [(ScanOptions.Grouping, String, String)] = [
        (.singleWork, L10n.text("这是一个作品"), L10n.text("整个文件夹算一个作品。本編、特典、台本都收在一起。")),
        (.childrenAsWorks, L10n.text("这里有很多作品"), L10n.text("每个子文件夹是一个作品。适合放了一堆作品的资料库目录。")),
        (.filesAsWorks, L10n.text("每个音频/视频文件算一个作品"), L10n.text("递归包含子文件夹，同名台本和图片随对应媒体；归属不明的资料不自动分配。已有作品不会自动拆分。")),
        (.automatic, L10n.text("让它自动判断"), L10n.text("按目录结构猜。猜错了可以重新导入再选。"))
    ]

    var body: some View {
        NavigationStack {
            AppList {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(folderURL.lastPathComponent)
                            .font(.headline)
                        Text(folderURL.deletingLastPathComponent().path)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                }

                Section("作品划分方式") {
                    ForEach(modes, id: \.0) { mode, title, detail in
                        Button {
                            grouping = mode
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: grouping == mode ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(grouping == mode ? AppTheme.iconTint : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(AppTheme.primaryText)
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.secondaryText)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("预览") {
                    if isLoading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在统计…").font(.footnote).foregroundStyle(AppTheme.secondaryText)
                        }
                    } else if let preview {
                        if let error = preview.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        } else {
                            LabeledContent("作品数", value: "\(preview.workCount)")
                            LabeledContent("音轨数", value: "\(preview.trackCount)")
                            if preview.videoCount > 0 {
                                LabeledContent("视频", value: L10n.text("\(preview.videoCount) 个"))
                            }
                            if !preview.titles.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("会得到这些作品：")
                                        .font(.caption2)
                                        .foregroundStyle(AppTheme.secondaryText)
                                    ForEach(preview.titles, id: \.self) { title in
                                        Text("· \(title)")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    if preview.workCount > preview.titles.count {
                                        Text("… 还有 \(preview.workCount - preview.titles.count) 个")
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.tertiaryText)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("导入文件夹"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        onConfirm(grouping)
                        dismiss()
                    }
                    .disabled(isLoading || preview?.errorMessage != nil || preview == nil)
                }
            }
            .task { await refreshPreview() }
            .onChange(of: grouping) { _, _ in
                Task { await refreshPreview() }
            }
        }
        .presentationDetents([.large])
    }

    private func refreshPreview() async {
        isLoading = true
        let result = await store.makePreview(url: folderURL, grouping: grouping)
        preview = result
        isLoading = false
    }
}
