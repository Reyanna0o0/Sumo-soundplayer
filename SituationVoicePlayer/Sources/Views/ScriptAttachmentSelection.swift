import SwiftUI

struct ScriptPreviewContent {
    let title: String
    let lines: [ScriptLine]
}

struct ScriptPreviewButton: View {
    let count: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("预览文字 · \(count) 行", systemImage: "text.alignleft")
                .font(.subheadline)
        }
        .buttonStyle(.borderless)
    }
}

struct ScriptPreviewPanel: View {
    let content: ScriptPreviewContent
    let close: () -> Void
    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(content.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button(action: close) { Label("收起预览", systemImage: "xmark.circle.fill") }
                    .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 38)
                    .accessibilityIdentifier("closeScriptPreview")
            }
            ScriptPreviewScroll(lines: content.lines).id(content.title)
        }
        .padding(.horizontal).padding(.bottom, 6)
        .background(AppTheme.textStyle(.bar, AppTheme.card))
    }
}

private struct ScriptPreviewScroll: View {
    let lines: [ScriptLine]
    @Environment(\.verticalSizeClass) private var verticalSize
    @ScaledMetric(relativeTo: .callout) private var lineHeight: CGFloat = 25

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(AppTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            if let stamp = lines[index].printedStartMS {
                                Text(SubtitleTime.clock(stamp) + (lines[index].printedEndMS.map {
                                    " – " + SubtitleTime.clock($0)
                                } ?? "")).font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
                            }
                            let prefix = lines[index].speaker.map { "\($0)：" } ?? ""
                            Text(prefix + lines[index].text)
                            if let translation = lines[index].translatedText, !translation.isEmpty {
                                Text(translation).foregroundStyle(AppTheme.secondaryText)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("scriptPreviewLine-\(index)")
                }
            }
            .padding(10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(verticalSize == .compact ? 110 : 200, 20 + CGFloat(lines.count) * lineHeight))
        .background(AppTheme.textStyle(.quaternary.opacity(0.45), AppTheme.surface), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityIdentifier("scriptPreviewScroll")
    }
}

struct WorkScriptFileList: View {
    let files: [WorkAttachmentRecord]
    @Binding var selectedIDs: [Int64]
    let read: (WorkAttachmentRecord) async throws -> ScriptReviewFile
    let onPrepared: ([ScriptReviewFile]) -> Void
    private var selected: [WorkAttachmentRecord] {
        selectedIDs.compactMap { id in files.first { $0.id == id } }
    }
    @State private var progress: String?
    @State private var failure: String?

    var body: some View {
        AppList {
            Section {
                ForEach(files) { record in
                    let index = selected.firstIndex(where: { $0.id == record.id })
                    Button {
                        if index != nil { selectedIDs.removeAll { $0 == record.id } } else { selectedIDs.append(record.id) }
                        failure = nil
                    } label: {
                        HStack(spacing: 12) {
                            ScriptOrderNumber(index: index)
                            ScriptFileLabel(path: record.attachment.relativePath)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityValue(index.map { L10n.text("第 \($0 + 1) 份") } ?? L10n.text("未选"))
                    .accessibilityIdentifier("selectWorkScript-\(record.id)")
                }
            } header: {
                Text("按顺序选择台本")
            } footer: {
                Text("下一步可核对每份台本对应的音轨。")
            }
        }
        .disabled(progress != nil)
        .safeAreaInset(edge: .bottom) {
            if let progress { ProgressView(progress).scriptStatusBar() }
            else if let failure { Text(failure).font(.footnote).foregroundStyle(.red).scriptStatusBar() }
        }
        .interactiveDismissDisabled(progress != nil)
        .navigationBarBackButtonHidden(progress != nil)
        .appNavigationColors().navigationTitle(L10n.text("选择台本附件"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("下一步（\(selected.count)）") { Task { await prepare() } }
                    .disabled(selected.isEmpty || progress != nil)
                    .accessibilityIdentifier("readSelectedScripts")
            }
        }
    }

    private func prepare() async {
        guard progress == nil, !selected.isEmpty else { return }
        failure = nil
        var loaded: [ScriptReviewFile] = []
        defer { progress = nil }
        for (index, record) in selected.enumerated() {
            progress = L10n.text("正在读取 \(index + 1)/\(selected.count) · \(record.attachment.fileName)")
            do {
                loaded.append(try await read(record))
            } catch {
                failure = L10n.text("「\(record.attachment.fileName)」读取失败。\(error.localizedDescription) 可重新选择或重试。")
                return
            }
        }
        onPrepared(loaded)
    }
}

struct ScriptOrderNumber: View {
    let index: Int?
    var body: some View {
        Group {
            if let index {
                Text("\(index + 1)").font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(AppTheme.onAccent).frame(minWidth: 26, minHeight: 26)
                    .background(AppTheme.accent, in: Capsule())
            } else {
                Image(systemName: "circle").font(.title3).foregroundStyle(AppTheme.tertiaryText)
                    .frame(width: 26, height: 26)
            }
        }.accessibilityHidden(true)
    }
}

extension View {
    func scriptStatusBar() -> some View {
        padding(12).frame(maxWidth: .infinity).background(AppTheme.textStyle(.bar, AppTheme.card))
    }
}

