import SwiftUI

struct SavedClipExportSheet: View {
    let entry: SavedPlaylistEntry
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var format: SavedClipExportFormat = .mp3
    @State private var job: UUID?
    @State private var progress = 0.0
    @State private var message: String?
    @State private var export: SavedClipFileExport?

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    Text(entry.title).font(.headline)
                    Picker("格式", selection: $format) {
                        ForEach(SavedClipExportFormat.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("clipExportFormat")
                    Text(format.detail).font(.footnote).foregroundStyle(AppTheme.secondaryText)
                }.disabled(job != nil)
                Section {
                    if job != nil {
                        ProgressView(value: progress) { Text("正在准备 \(format.title)…") }
                            .accessibilityIdentifier("clipExportProgress")
                        Button("取消转换", role: .cancel) { job = nil }
                            .accessibilityIdentifier("clipExportCancel")
                    } else {
                        Button("导出 \(format.title)…") { progress = 0; job = UUID() }
                            .accessibilityIdentifier("clipExportStart")
                    }
                } footer: { Text("导出新的音频副本，保留原摘选。") }
            }
            .appNavigationColors().navigationTitle(L10n.text("导出音频")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { job = nil; dismiss() } } }
            .interactiveDismissDisabled(job != nil)
            .sheet(item: $export) { request in
                ClipFileDestination(export: request) { export = nil; dismiss() }
                    .onDisappear { request.removeTemporaryCopy() }
            }
            .alert("导出失败", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好") { message = nil }
            } message: { Text(message ?? "") }
            .task(id: job) {
                guard let expected = job else { return }
                do {
                    let request = try await store.prepareClipExport(entry, format: format) { value in
                        Task { @MainActor in
                            guard job == expected else { return }
                            progress = value
                        }
                    }
                    try Task.checkCancellation()
                    guard job == expected else { return }
                    export = request
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, job == expected else { return }
                    message = error.localizedDescription
                }
                if job == expected { job = nil }
            }
        }
    }
}
