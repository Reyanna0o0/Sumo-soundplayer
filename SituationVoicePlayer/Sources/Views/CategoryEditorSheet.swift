import SwiftUI

/// 新建/重命名分组的小表单。
///
/// 为什么不用 `.alert` 里的 TextField：同一个视图上挂两个 alert 时
/// SwiftUI 只会让最后一个生效（前一个静默失效），这个坑很隐蔽。
/// 用 sheet 既能避免冲突，又能自动聚焦输入框。
struct CategoryEditorSheet: View {
    enum Mode: Equatable {
        case create
        case rename(original: String)

        var title: String {
            switch self {
            case .create: return L10n.text("新建分组")
            case .rename: return L10n.text("重命名分组")
            }
        }

        var confirmTitle: String {
            switch self {
            case .create: return L10n.text("创建")
            case .rename: return L10n.text("保存")
            }
        }
    }

    let mode: Mode
    let existingTitles: [String]
    @Binding var text: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        if trimmed.isEmpty { return L10n.text("名称不能为空") }
        let duplicated = existingTitles.contains { title in
            // 重命名时允许保持原名
            if case .rename(let original) = mode, title == original { return false }
            return title == trimmed
        }
        if duplicated { return L10n.text("已经有同名分组了") }
        return nil
    }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField("分组名称，例如「本篇」", text: $text)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(confirmIfValid)
                } footer: {
                    if let validationMessage {
                        Text(validationMessage).foregroundStyle(.red)
                    } else {
                        Text("创建后可以把曲目拖到这个分组里。")
                    }
                }
            }
            .appNavigationColors().navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.confirmTitle) { confirmIfValid() }
                        .disabled(validationMessage != nil)
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.height(220)])
    }

    private func confirmIfValid() {
        guard validationMessage == nil else { return }
        onConfirm(trimmed)
    }
}
