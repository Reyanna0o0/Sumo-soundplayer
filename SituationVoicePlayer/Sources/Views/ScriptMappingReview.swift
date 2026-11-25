import SwiftUI

struct ScriptReviewFile {
    let name: String
    let displayPath: String
    let mapping: OrderedScriptMapping
    var rows: [ScriptImportAssignment]
    var orderedIDs: [Int64] = []
    var starts: [Int64: Int] = [:]

    init(name: String, result: WorkScriptMatching, displayPath: String? = nil) {
        self.name = name
        self.displayPath = displayPath ?? name
        mapping = OrderedScriptMapping(sections: result.assignableSections)
        rows = result.suggestedAssignments
    }

    init(name: String, sections: [ScriptSection], tracks: [TrackRecord]) {
        self.name = name; displayPath = name
        mapping = OrderedScriptMapping(sections: sections)
        rows = ScriptImportPlan.make(sections: sections, tracks: tracks)
    }

    /// 在同一首上有多个候选时，只有可证实的对应译本可以同时预选。
    static func reconciled(_ files: [Self]) -> [Self] {
        let editions = files.map { file in
            ScriptEdition(path: file.name, digest: file.name, tracks: Set(file.mapping.sections.compactMap(\.trackNumber)))
        }
        var candidates: [Int64: [ScriptEdition]] = [:]
        for (file, edition) in zip(files, editions) {
            for id in Set(file.rows.compactMap(\.trackID)) { candidates[id, default: []].append(edition) }
        }
        let accepted = candidates.mapValues { ScriptEdition.selection(from: $0) }
        return files.map { file in
            var result = file
            for index in result.rows.indices {
                if let id = result.rows[index].trackID, accepted[id]?.contains(file.name) != true {
                    result.rows[index].trackID = nil
                    result.rows[index].explanation = L10n.text("另有台本也可能对应这首，请确认。")
                }
            }
            return result
        }
    }
}

struct ScriptFileLabel: View {
    let path: String

    var body: some View {
        let directory = (path as NSString).deletingLastPathComponent
        VStack(alignment: .leading, spacing: 3) {
            Text((path as NSString).lastPathComponent)
                .font(.body).foregroundStyle(AppTheme.primaryText)
            if !directory.isEmpty {
                Text(directory).font(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(2)
                    .truncationMode(.head)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

private enum ScriptReviewEditor: Identifiable {
    case target(file: Int, row: Int)
    case ordered(file: Int)
    case batch

    var id: String {
        switch self {
        case .target(let file, let row): return "target-\(file)-\(row)"
        case .ordered(let file): return "ordered-\(file)"
        case .batch: return "batch"
        }
    }
}

struct ScriptMappingReview: View {
    @Binding var files: [ScriptReviewFile]
    let tracks: [TrackRecord]
    let mergedCopies: Int
    let save: (Bool) async throws -> Void
    @State private var expanded: Set<Int> = []
    @State private var editor: ScriptReviewEditor?
    @State private var preview: ScriptPreviewContent?
    @State private var activate = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmPartial = false

    private var selectedCount: Int { Set(files.flatMap { $0.rows.compactMap(\.trackID) }).count }
    private var pending: Int { files.reduce(0) { $0 + $1.rows.filter { $0.trackID == nil }.count } }

    var body: some View {
        AppList {
            if mergedCopies > 0 { Text("已合并 \(mergedCopies) 份重复附件。").font(.footnote) }
            if tracks.isEmpty { Text("作品中没有可配对的音轨。").foregroundStyle(AppTheme.secondaryText) }
            if files.count > 1 {
                Button("按顺序点选音轨", systemImage: "list.number") { open(.batch) }
                    .disabled(tracks.isEmpty)
                    .accessibilityIdentifier("batchOrderedTracks")
            }
            ForEach(files.indices, id: \.self) { index in
                fileSection(index)
            }
            Section {
                Toggle("切换到导入的台本", isOn: $activate)
                    .accessibilityIdentifier("activateImportedScript")
            } footer: {
                Text(activate ? L10n.text("同一轨导入多份台本时，显示先选的那一份。") : L10n.text("已有字幕继续显示。首次添加台本的音轨会直接显示新台本。"))
            }
        }
        .disabled(saving)
        .safeAreaInset(edge: .bottom) {
            if let preview {
                ScriptPreviewPanel(content: preview) { self.preview = nil }
            } else if saving {
                ProgressView("正在保存台本…").scriptStatusBar()
            } else if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red).scriptStatusBar()
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("核对台本与音轨"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(saving)
        .interactiveDismissDisabled(saving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("导入") {
                    if pending > 0 { confirmPartial = true } else { commit() }
                }
                .disabled(selectedCount == 0 || saving)
                .accessibilityIdentifier("importScript")
            }
        }
        .alert("还有 \(pending) 项未选音轨", isPresented: $confirmPartial) {
            Button("仅导入已选的 \(selectedCount) 轨") { commit() }
            Button("继续配对", role: .cancel) {}
        }
        .sheet(item: $editor) { edit in
            NavigationStack {
                switch edit {
                case .target(let file, let row):
                    ScriptTargetPicker(section: files[file].rows[row], tracks: tracks,
                                       reserved: Set(files[file].rows.filter { $0.id != files[file].rows[row].id }.compactMap(\.trackID))) { id in
                        files[file].rows[row].trackID = id
                        files[file].rows[row].explanation = id == nil ? L10n.text("未选音轨") : L10n.text("手动对应")
                        files[file].orderedIDs = []
                        files[file].starts = [:]
                        editor = nil
                    }
                case .ordered(let index):
                    OrderedScriptTracksView(mapping: files[index].mapping, tracks: tracks, onApply: { rows, ids, starts in
                        files[index].rows = rows
                        files[index].orderedIDs = ids
                        files[index].starts = starts
                    }, selectedIDs: files[index].orderedIDs, starts: files[index].starts)
                case .batch:
                    BatchScriptOrderView(files: files, tracks: tracks) { updated in
                        files = updated
                        editor = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fileSection(_ index: Int) -> some View {
        let file = files[index]
        let isOpen = files.count == 1 || expanded.contains(index)
        Section {
            if files.count == 1 {
                summary(file, index: index)
            } else {
                Button {
                    if isOpen { expanded.remove(index) } else { expanded.insert(index) }
                    preview = nil
                } label: {
                    HStack {
                        summary(file, index: index)
                        Spacer()
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.caption.bold())
                            .foregroundStyle(AppTheme.secondaryText)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("expandScript-\(index)")
            }
            if isOpen {
                HStack {
                    ScriptPreviewButton(count: file.mapping.lines.count) {
                        preview = ScriptPreviewContent(title: (file.displayPath as NSString).lastPathComponent, lines: file.mapping.lines)
                    }
                    .accessibilityIdentifier("scriptPreview-\(index)")
                    Spacer(minLength: 12)
                    Button("按顺序选轨") { open(.ordered(file: index)) }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                        .disabled(tracks.isEmpty)
                        .accessibilityIdentifier("chooseOrderedScriptTracks-\(index)")
                }
                ForEach(file.rows.indices, id: \.self) { row in
                    assignment(file: index, row: row)
                }
            }
        }
    }

    private func summary(_ file: ScriptReviewFile, index: Int) -> some View {
        let count = file.rows.filter { $0.trackID != nil }.count
        let pending = file.rows.count - count
        let bilingual = file.mapping.lines.filter { $0.translatedText?.isEmpty == false }.count
        return VStack(alignment: .leading, spacing: 4) {
            ScriptFileLabel(path: file.displayPath)
            Text(L10n.text("\(file.mapping.sections.count) 段 · 已对应 \(count) 轨") + (pending == 0 ? "" : L10n.text(" · \(pending) 项待选")))
                .font(.caption).foregroundStyle(AppTheme.secondaryText)
                .accessibilityIdentifier("scriptDocumentSummary-\(index)")
            if bilingual > 0 {
                Text(L10n.text("已识别 \(bilingual) 组双语") + (bilingual == file.mapping.lines.count
                     ? "" : L10n.text(" · 其余 \(file.mapping.lines.count - bilingual) 段保留原样")))
                    .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("scriptBilingualSummary-\(index)")
            }
        }
    }

    private func assignment(file: Int, row: Int) -> some View {
        let item = files[file].rows[row]
        let track = tracks.first { $0.id == item.trackID }
        let trackLabel = track.map { match in
            let sameName = tracks.contains { $0.id != match.id && $0.fileName == match.fileName }
            return sameName ? (match.relativePath ?? match.fileName) : match.fileName
        }
        return Button { open(.target(file: file, row: row)) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.section.localizedDisplayName).font(.subheadline.weight(.medium)).foregroundStyle(AppTheme.primaryText)
                        .lineLimit(2)
                    Text(trackLabel ?? L10n.text("选择对应音轨"))
                        .font(.subheadline).foregroundStyle(track == nil ? AppTheme.accent : .secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(AppTheme.tertiaryText)
            }
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scriptAssignment-\(file)-\(row)")
    }

    private func open(_ action: ScriptReviewEditor) {
        preview = nil
        errorMessage = nil
        editor = action
    }

    private func commit() {
        guard !saving, selectedCount > 0 else { return }
        preview = nil
        errorMessage = nil
        saving = true
        Task {
            defer { saving = false }
            do { try await save(activate) }
            catch { errorMessage = L10n.text("保存失败，可以重试。\n\(error.localizedDescription)") }
        }
    }
}

private struct ScriptTargetPicker: View {
    let section: ScriptImportAssignment
    let tracks: [TrackRecord]
    let reserved: Set<Int64>
    let apply: (Int64?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var preview: ScriptPreviewContent?

    var body: some View {
        AppList {
            Section {
                Text(section.section.localizedDisplayName).font(.headline)
                Text(section.explanation).font(.footnote).foregroundStyle(AppTheme.secondaryText)
                ScriptPreviewButton(count: section.section.lines.count) {
                    preview = ScriptPreviewContent(title: section.section.localizedDisplayName, lines: section.section.lines)
                }
                .accessibilityIdentifier("previewSelectedScriptSection")
                Button("跳过这段") { apply(nil) }.accessibilityIdentifier("skipScriptAssignment")
            }
            Section("对应音轨") {
                ForEach(tracks.filter { query.isEmpty || ($0.relativePath ?? $0.fileName).localizedStandardContains(query) }) { track in
                    Button { apply(track.id) } label: {
                        HStack {
                            ScriptFileLabel(path: track.relativePath ?? track.fileName)
                            Spacer()
                            if track.id == section.trackID { Image(systemName: "checkmark") }
                            else if reserved.contains(track.id) { Text("本台本内已选").font(.caption) }
                        }.contentShape(Rectangle())
                    }
                    .disabled(reserved.contains(track.id))
                    .accessibilityIdentifier("assignmentTrack-\(track.id)")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let preview { ScriptPreviewPanel(content: preview) { self.preview = nil } }
        }
        .searchable(text: $query, prompt: L10n.text("搜索音轨"))
        .appNavigationColors().navigationTitle(L10n.text("选择对应音轨"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        }
    }
}

/// 逐个沿用附件、段落的点选顺序。点「应用」前，核对页保留原来的分配。
private struct BatchScriptOrderView: View {
    let files: [ScriptReviewFile]
    let tracks: [TrackRecord]
    let apply: ([ScriptReviewFile]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [Int64] = []
    @State private var preview: ScriptPreviewContent?

    private struct Position {
        let file: Int
        let row: Int
    }

    private var positions: [Position] {
        files.indices.flatMap { file in files[file].rows.indices.map { Position(file: file, row: $0) } }
    }

    var body: some View {
        let positions = positions
        let current = positions.indices.contains(selected.count) ? positions[selected.count] : nil
        AppList {
            if let current {
                Section {
                    ForEach(tracks) { track in
                        let previous = selected.indices.first { positions[$0].file == current.file && selected[$0] == track.id }
                        Button {
                            selected.append(track.id)
                            preview = nil
                        } label: {
                            HStack {
                                ScriptOrderNumber(index: previous)
                                ScriptFileLabel(path: track.relativePath ?? track.fileName)
                                Spacer()
                            }.contentShape(Rectangle())
                        }
                        .disabled(previous != nil)
                        .accessibilityIdentifier("batchScriptTrack-\(track.id)")
                    }
                } header: { Text("点选对应音轨") }
            } else {
                Section("按点选顺序配对") {
                    ForEach(selected.indices, id: \.self) { index in
                        let part = positions[index]
                        VStack(alignment: .leading, spacing: 5) {
                            Text(files[part.file].rows[part.row].section.localizedDisplayName)
                            Text(tracks.first { $0.id == selected[index] }?.fileName ?? "").font(.subheadline)
                                .foregroundStyle(AppTheme.secondaryText)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if let current {
                let file = files[current.file]
                let section = file.rows[current.row].section
                VStack(alignment: .leading, spacing: 4) {
                    Text("第 \(selected.count + 1)/\(positions.count) 项 · \((file.displayPath as NSString).lastPathComponent)")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText).lineLimit(2)
                    Text(section.localizedDisplayName).font(.headline).lineLimit(2)
                    ScriptPreviewButton(count: section.lines.count) {
                        preview = ScriptPreviewContent(title: section.localizedDisplayName, lines: section.lines)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 6).background(AppTheme.textStyle(.bar, AppTheme.card))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let preview { ScriptPreviewPanel(content: preview) { self.preview = nil } }
        }
        .appNavigationColors().navigationTitle(L10n.text("按顺序点选音轨"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if !selected.isEmpty { selected.removeLast(); preview = nil }
                } label: { Label("撤销上一步", systemImage: "arrow.uturn.backward") }
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("undoBatchTrack")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("应用") {
                    guard positions.count == selected.count, !selected.isEmpty else { return }
                    var result = files
                    for (part, id) in zip(positions, selected) {
                        result[part.file].rows[part.row].trackID = id
                        result[part.file].rows[part.row].explanation = L10n.text("按点选顺序配对")
                        result[part.file].orderedIDs = []
                        result[part.file].starts = [:]
                    }
                    apply(result)
                }
                .disabled(current != nil || selected.isEmpty)
                .accessibilityIdentifier("applyBatchOrder")
            }
        }
    }
}
