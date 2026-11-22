import SwiftUI
import UniformTypeIdentifiers

struct WorkScriptImportSheet: View {
    let work: WorkRecord
    let store: LibraryStore
    var onImported: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var subtitles: SubtitleController
    private enum Route: Hashable { case attachments, review }
    @State private var route: [Route] = []
    @State private var tracks: [TrackRecord] = []
    @State private var workScripts: [WorkAttachmentRecord] = []
    @State private var drafts: [ScriptReviewFile] = []
    @State private var mergedCopies = 0
    @State private var selectedFileIDs: [Int64] = []
    @State private var showPicker = false
    @State private var showScriptbin = false
    @State private var busyText: String?
    @State private var report: WorkPDFMatchReport?
    @State private var errorMessage: String?
    @State private var receipt: String?
    @State private var successToken: UUID?

    var body: some View {
        NavigationStack(path: $route) {
            AppForm {
                Section {
                    if !workScripts.isEmpty {
                        NavigationLink("从作品附件选择台本", value: Route.attachments)
                            .accessibilityIdentifier("chooseAttachedScript")
                    }
                    Button("从「文件」选择台本", systemImage: "doc.badge.plus") { showPicker = true }
                        .accessibilityIdentifier("chooseScript")
                    Button("从 Scriptbin 链接导入", systemImage: "link") { showScriptbin = true }
                        .accessibilityIdentifier("chooseScriptbin")
                    Button("重新匹配作品内的 PDF 台本", action: rematch)
                        .accessibilityIdentifier("rematchWorkScript")
                } header: { Text(work.title).textCase(nil) }
                if let busyText { ProgressView(busyText) }
                if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                if let receipt { Label(receipt, systemImage: "checkmark.circle").font(.footnote) }
                if let report {
                    Section("匹配结果") {
                        Text(report.summary).font(.footnote)
                        ForEach(report.files) { file in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(file.record.attachment.relativePath).font(.subheadline)
                                Text(file.detail).font(.caption).foregroundStyle(AppTheme.secondaryText)
                                Button("手动指定音轨") { readAttachment(file.record) }
                                    .accessibilityIdentifier("assignReportedPDF-\(file.id)")
                            }
                        }
                    }
                }
            }
            .disabled(busyText != nil)
            .appNavigationColors().navigationTitle(L10n.text("导入作品台本"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(receipt == nil ? L10n.text("关闭") : L10n.text("完成")) { dismiss() }.disabled(busyText != nil)
                }
            }
            .navigationDestination(for: Route.self) { step in
                switch step {
                case .attachments:
                    WorkScriptFileList(files: workScripts, selectedIDs: $selectedFileIDs, read: loadAttachment, onPrepared: present)
                case .review:
                    ScriptMappingReview(files: $drafts, tracks: tracks, mergedCopies: mergedCopies, save: save)
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.pdf, .plainText, .text],
                          allowsMultipleSelection: false, onCompletion: readSelection)
        }
        .sheet(isPresented: $showScriptbin) {
            ScriptbinImportSheet(work: work, store: store) {
                refreshFiles(); showSuccess(L10n.text("Scriptbin 正文已保存，可离线阅读。"))
                receipt = L10n.text("Scriptbin 正文已保存，可离线阅读。"); onImported()
            }
        }
        .interactiveDismissDisabled(busyText != nil)
        .overlay {
            if successToken != nil { ImportSuccessToast().accessibilityIdentifier("scriptImportSuccess") }
        }
        .task(id: successToken) {
            guard successToken != nil else { return }
            do { try await Task.sleep(for: .milliseconds(2600)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { successToken = nil }
        }
        .task {
            tracks = store.tracks(for: work).filter { !$0.isVideo }
            do { try await store.refreshAttachments(for: work) }
            catch { errorMessage = L10n.text("刷新作品附件失败：\(error.localizedDescription)") }
            refreshFiles()
        }
    }

    private func refreshFiles() {
        workScripts = store.attachmentRecords(for: work).filter {
            $0.attachment.kind == .pdf || $0.attachment.kind == .text
        }
    }

    private func rematch() {
        guard busyText == nil else { return }
        busyText = L10n.text("正在匹配作品台本…")
        receipt = nil
        report = nil
        errorMessage = nil
        Task {
            defer { busyText = nil }
            do {
                let result = try await store.rematchScripts(for: work)
                report = result
                refreshFiles()
                if let id = subtitles.loadedTrackID, tracks.contains(where: { $0.id == id }) { subtitles.forceReload() }
                if result.matchedCount > 0 { showSuccess(result.summary) }
                onImported()
            } catch { errorMessage = L10n.text("匹配失败：\(error.localizedDescription)") }
        }
    }

    private func readSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
        case .success(let urls):
            guard let url = urls.first else { return }
            busyText = L10n.text("正在读取 \(url.lastPathComponent)…")
            Task {
                defer { busyText = nil }
                do {
                    let result = try await ScriptExtractor.readForImport(url, name: url.lastPathComponent, tracks: tracks)
                    present([ScriptReviewFile(name: url.lastPathComponent, result: result)])
                } catch { errorMessage = L10n.text("读取失败：\(error.localizedDescription)") }
            }
        }
    }

    private func loadAttachment(_ record: WorkAttachmentRecord) async throws -> ScriptReviewFile {
        let (url, lease) = try store.openAttachment(record, in: work)
        let result = try await ScriptExtractor.readForImport(url, name: record.attachment.fileName, tracks: tracks,
                                                            workRoot: lease.directory.path, lease: lease)
        let name = await AutomaticPDFScripts.sourceName(for: record, url: url, lease: lease, siblings: workScripts)
        return ScriptReviewFile(name: name, result: result, displayPath: record.attachment.relativePath)
    }

    private func readAttachment(_ record: WorkAttachmentRecord) {
        busyText = L10n.text("正在读取 \(record.attachment.fileName)…")
        Task {
            defer { busyText = nil }
            do { present([try await loadAttachment(record)]) }
            catch { errorMessage = L10n.text("读取失败：\(error.localizedDescription)") }
        }
    }

    private func present(_ selections: [ScriptReviewFile]) {
        var names: Set<String> = []
        let documents = selections.filter { names.insert($0.name).inserted }
        guard !documents.isEmpty else { return }
        mergedCopies = selections.count - documents.count
        let sameFiles = documents.count == drafts.count && zip(documents, drafts).allSatisfy {
            $0.name == $1.name && $0.mapping.sections == $1.mapping.sections
        }
        if !sameFiles { drafts = ScriptReviewFile.reconciled(documents) }
        receipt = nil
        errorMessage = nil
        route.append(.review)
    }

    private func save(activate: Bool) async throws {
        let selected = drafts.compactMap { file -> (name: String, rows: [ScriptImportAssignment])? in
            let rows = file.rows.filter { $0.trackID != nil }
            return rows.isEmpty ? nil : (file.name, rows)
        }
        _ = try await store.saveManualScripts(selected, for: tracks, activate: activate)
        let ids = Set(selected.flatMap { $0.rows.compactMap(\.trackID) })
        if let id = subtitles.loadedTrackID, ids.contains(id) { subtitles.forceReload() }
        let skipped = drafts.reduce(0) { $0 + $1.rows.filter { $0.trackID == nil }.count }
        let summary = L10n.text("已将 \(selected.count) 份台本导入 \(ids.count) 条音轨。") + (skipped > 0 ? L10n.text("另有 \(skipped) 项未导入。") : "")
        receipt = summary
        report = nil
        errorMessage = nil
        route = []
        // 移出导航栈后清理草稿；成功返回入口时不会继续编辑旧数据。
        selectedFileIDs.removeAll()
        drafts.removeAll()
        showSuccess(summary)
        onImported()
    }

    private func showSuccess(_ summary: String) {
        withAnimation(.easeOut(duration: 0.15)) { successToken = UUID() }
        UIAccessibility.post(notification: .announcement, argument: L10n.text("导入成功。\(summary)"))
    }
}
