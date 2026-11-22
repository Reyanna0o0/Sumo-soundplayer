import SwiftUI

struct OrderedScriptTracksView: View {
    let mapping: OrderedScriptMapping
    let tracks: [TrackRecord]
    let onApply: ([ScriptImportAssignment], [Int64], [Int64: Int]) -> Void
    @State var selectedIDs: [Int64]
    @State var starts: [Int64: Int]
    @Environment(\.dismiss) private var dismiss
    @State private var showBoundaries = false

    private var needsBoundaries: Bool {
        selectedIDs.count > 1 && !mapping.usesHeadings(for: selectedIDs.count)
    }

    var body: some View {
        AppList {
            Section {
                ForEach(tracks) { track in
                    let index = selectedIDs.firstIndex(of: track.id)
                    Button {
                        if let index { selectedIDs.remove(at: index) }
                        else { selectedIDs.append(track.id) }
                        starts.removeValue(forKey: track.id)
                        if let first = selectedIDs.first { starts.removeValue(forKey: first) }
                    } label: {
                        HStack(spacing: 12) {
                            ScriptOrderNumber(index: index)
                            ScriptFileLabel(path: track.relativePath ?? track.fileName)
                            Spacer()
                        }.contentShape(Rectangle())
                    }
                    .disabled(index == nil && selectedIDs.count >= mapping.lines.count)
                    .accessibilityValue(index.map { L10n.text("第\($0 + 1)个") } ?? L10n.text("未选"))
                    .accessibilityIdentifier("orderedScriptTrack-\(track.id)")
                }
            } header: { Text("按台本先后点选 · 已选 \(selectedIDs.count) 轨") }
        }
        .safeAreaInset(edge: .bottom) {
            if !selectedIDs.isEmpty {
                Text(summary).font(.footnote).foregroundStyle(AppTheme.secondaryText).scriptStatusBar()
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("按顺序选音轨"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(needsBoundaries ? L10n.text("下一步") : L10n.text("应用")) {
                    if needsBoundaries { showBoundaries = true } else { apply() }
                }
                .disabled(selectedIDs.isEmpty)
                .accessibilityIdentifier("applyOrderedScript")
            }
        }
        .navigationDestination(isPresented: $showBoundaries) {
            AppList {
                Section {
                    ForEach(Array(selectedIDs.dropFirst().enumerated()), id: \.element) { offset, id in
                        let name = tracks.first { $0.id == id }?.fileName ?? ""
                        NavigationLink {
                            ScriptStartingLineList(lines: mapping.lines, selected: starts[id],
                                isAllowed: { canStart(at: $0, order: offset + 1) },
                                onSelect: { starts[id] = $0 })
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).lineLimit(2)
                                Text(starts[id].map { L10n.text("第 \($0 + 1) 行 · \(mapping.lines[$0].text)") } ?? L10n.text("选择第一句"))
                                    .font(.caption).lineLimit(2).foregroundStyle(AppTheme.secondaryText)
                            }
                        }.accessibilityIdentifier("chooseScriptBoundary-\(id)")
                    }
                } footer: { Text("第一条音轨从第 1 行开始。为后面的音轨各选一句，作为它的开头。") }
            }
            .appNavigationColors().navigationTitle(L10n.text("各轨从哪句开始"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用", action: apply)
                        .disabled(mapping.assignments(trackIDs: selectedIDs, starts: starts) == nil)
                        .accessibilityIdentifier("applyScriptBoundaries")
                }
            }
        }
    }

    private var summary: String {
        if mapping.usesHeadings(for: selectedIDs.count) { return L10n.text("将按点选顺序分配 \(mapping.sections.count) 段。") }
        if selectedIDs.count == 1 { return L10n.text("整份台本将配给这一条音轨。") }
        return L10n.text("下一步选择每条音轨的第一句。")
    }

    private func apply() {
        guard let assignments = mapping.assignments(trackIDs: selectedIDs, starts: starts) else { return }
        onApply(assignments, selectedIDs, starts)
        dismiss()
    }

    private func canStart(at line: Int, order: Int) -> Bool {
        let previous = selectedIDs.prefix(order).compactMap { starts[$0] }.max() ?? 0
        let next = selectedIDs.dropFirst(order + 1).compactMap { starts[$0] }.min() ?? mapping.lines.count
        return line > previous && line < next && line >= order
            && mapping.lines.count - line >= selectedIDs.count - order
    }
}

private struct ScriptStartingLineList: View {
    let lines: [ScriptLine]
    let selected: Int?
    let isAllowed: (Int) -> Bool
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(lines.indices, id: \.self) { index in
            Button {
                onSelect(index)
                dismiss()
            } label: {
                HStack {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lines[index].text).lineLimit(3)
                        if let translation = lines[index].translatedText, !translation.isEmpty {
                            Text(translation).font(.subheadline).foregroundStyle(AppTheme.secondaryText).lineLimit(3)
                        }
                    }
                    if selected == index { Image(systemName: "checkmark") }
                }
            }
            .appListRows()
            .disabled(!isAllowed(index))
            .accessibilityIdentifier("scriptStartingLine-\(index)")
        }
        .appListSurface()
        .appNavigationColors().navigationTitle(L10n.text("选择这条音轨的第一句"))
    }
}
