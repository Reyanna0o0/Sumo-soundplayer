import SwiftUI

/// 诊断日志：把运行时的日志文件列出来看，方便在手机上直接排查。
struct DiagnosticsView: View {
    @State private var logText = ""
    @State private var isLoading = true

    var body: some View {
        AppList {
            if isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("读取中…").foregroundStyle(AppTheme.secondaryText)
                }
            } else if logText.isEmpty {
                ContentUnavailableView {
                    Label("没有日志", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("导入作品或匹配台本后，可以在这里查看记录。")
                }
            } else {
                Section("debug.log") {
                    Text(logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("诊断日志"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return }

        let url = documents.appendingPathComponent("debug.log")
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        logText = content.components(separatedBy: "\n").suffix(120).joined(separator: "\n")
    }
}
