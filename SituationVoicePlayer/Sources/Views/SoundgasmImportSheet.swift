import SwiftUI

struct SoundgasmImportSheet: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var page: SoundgasmPage?
    @State private var library: MediaLibraryKind = .personal
    @State private var creatorID: Int64?
    @State private var busy = false
    @State private var progress = ""
    @State private var errorText: String?
    @State private var operation: Task<Void, Never>?
    var onImported: () -> Void = {}

    var body: some View {
        NavigationStack {
            AppForm {
                Section("Soundgasm 作品链接") {
                    TextField("https://soundgasm.net/u/…/…", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("soundgasmURL")
                        .onChange(of: input) { _, _ in page = nil; errorText = nil }
                    Button("读取作品", action: read).accessibilityIdentifier("soundgasmRead")
                }.disabled(busy)
                if let page {
                    Section("导入预览") { DirectLinkDetails(metadata: page.metadata) }
                    Section {
                        Picker("媒体库", selection: $library) {
                            ForEach(MediaLibraryKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        if library == .personal {
                            Picker("创作者", selection: $creatorID) {
                                Text("暂不指定").tag(Int64?.none)
                                ForEach(store.creators) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    } header: { Text("导入到") }
                      footer: { Text("下载音频副本到 App。网页上传账号单独保存；创作者由你指定。") }
                    .disabled(busy)
                    Button("下载并导入", action: save).disabled(busy)
                        .accessibilityIdentifier("soundgasmImport")
                }
                if busy { ProgressView(progress) }
                if let errorText { Text(errorText).foregroundStyle(.orange).accessibilityIdentifier("directLinkError") }
            }
            .appNavigationColors().navigationTitle(L10n.text("导入 Soundgasm"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { operation?.cancel(); dismiss() } } }
            .interactiveDismissDisabled(busy)
            .onDisappear { operation?.cancel() }
        }
    }
    private func read() {
        busy = true; errorText = nil; progress = L10n.text("正在读取作品…"); page = nil
        operation = Task {
            defer { busy = false }
            do {
                let value = try await SoundgasmImporter.read(DirectLink(input, site: .soundgasm))
                try Task.checkCancellation(); page = value
            } catch { if !(error is CancellationError) { errorText = error.localizedDescription } }
        }
    }
    private func save() {
        guard let page else { return }
        busy = true; errorText = nil; progress = L10n.text("正在下载音频…")
        operation = Task {
            defer { busy = false }
            do {
                try await store.importSoundgasm(page, library: library, creatorID: creatorID) { bytes, total in
                    Task { @MainActor in
                        progress = L10n.text("已下载 ") + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                            + (total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : "")
                    }
                }
                dismiss(); onImported()
            } catch { if !(error is CancellationError) { errorText = error.localizedDescription } }
        }
    }
}

struct DirectLinkDetails: View {
    let metadata: DirectLinkMetadata
    var body: some View {
        Text(metadata.title).font(.headline)
        LabeledContent("网页上传账号", value: metadata.uploadAccount)
        if let url = URL(string: metadata.sourceURL) { Link("查看原网页", destination: url) }
        if !metadata.explicitCredits.isEmpty { Text(metadata.explicitCredits).textSelection(.enabled) }
        if !metadata.description.isEmpty { Text(metadata.description).font(.footnote).textSelection(.enabled) }
    }
}
