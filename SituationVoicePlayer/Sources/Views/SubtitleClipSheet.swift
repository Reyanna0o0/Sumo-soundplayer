import SwiftUI

struct SubtitleClipDraft: Identifiable {
    let id = UUID()
    let item: PlaybackQueueItem
    let first: SubtitleCue?
    let last: SubtitleCue?
    let durationMS: Int
    let startMS: Int
    let endMS: Int

    init(item: PlaybackQueueItem, first: SubtitleCue? = nil, last: SubtitleCue? = nil,
         durationMS: Int, startMS: Int, endMS: Int) {
        self.item = item; self.first = first; self.last = last
        self.durationMS = durationMS; self.startMS = startMS; self.endMS = endMS
    }
    var isSubtitleSelection: Bool { first != nil && last != nil }
}

/// 此处调整的是摘取范围，不写回原字幕。
struct SubtitleClipSheet: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let draft: SubtitleClipDraft
    let onSaved: () -> Void
    @State private var startMS: Int
    @State private var endMS: Int
    @State private var groupID: Int64?
    @State private var editingTime: PlaybackTimeEndpoint?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var workTitle: String

    init(draft: SubtitleClipDraft, onSaved: @escaping () -> Void) {
        self.draft = draft
        self.onSaved = onSaved
        _startMS = State(initialValue: draft.startMS)
        _endMS = State(initialValue: draft.endMS)
        _workTitle = State(initialValue: draft.item.workTitle)
    }

    private var groups: [SavedPlaylistGroup] { store.playlistGroups.filter(\.isClips) }
    private var validRange: Bool { startMS >= 0 && endMS > startMS && endMS <= draft.durationMS }

    var body: some View {
        NavigationStack {
            Form {
                if let first = draft.first, let last = draft.last {
                    Section("所选台词") {
                        quote(first, endpoint: .start)
                        quote(last, endpoint: .end)
                    }
                } else {
                    Section("所选音频") {
                        Text(draft.item.trackTitle).font(.headline)
                        Text(workTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        timeButton(.start, milliseconds: startMS)
                        Text("—").foregroundStyle(.secondary)
                        timeButton(.end, milliseconds: endMS)
                    }
                    if validRange {
                        Text("摘取时长 \(SubtitleTime.clockWithMilliseconds(endMS - startMS))")
                            .font(.subheadline.monospacedDigit())
                            .accessibilityIdentifier("subtitleClipDuration")
                    } else {
                        Text("结束时间需晚于开始时间，且不能超过音频结尾。")
                            .foregroundStyle(.red).font(.subheadline)
                    }
                } header: {
                    Text("摘取时间")
                } footer: {
                    Text("点开始或结束时间，滚动微调。调整时间不会修改原字幕。")
                }
                Section("保存到摘选") {
                    Picker("集合", selection: $groupID) {
                        ForEach(groups) { group in Text(group.name).tag(Optional(group.id)) }
                    }
                    .accessibilityIdentifier("subtitleClipGroup")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            if saving { ProgressView().padding(.trailing, 4) }
                            Text(saving ? L10n.text("正在保存…") : L10n.text("保存摘选"))
                            Spacer()
                        }
                    }
                    .disabled(!validRange || groupID == nil || saving)
                    .accessibilityIdentifier("saveSubtitleClip")
                }
            }
            .disabled(saving)
            .navigationTitle(L10n.text("确认摘取"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(draft.isSubtitleSelection ? L10n.text("返回选句") : L10n.text("取消")) { dismiss() }.disabled(saving)
                        .accessibilityIdentifier("returnSubtitleSelection")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .interactiveDismissDisabled(saving)
        .onAppear { if groupID == nil { groupID = groups.first?.id } }
        .onChange(of: store.contentRevision, initial: true) { _, _ in
            workTitle = store.displayWorkTitle(for: draft.item)
        }
        .sheet(item: $editingTime) { endpoint in
            PlaybackTimeWheel(title: endpoint == .start ? L10n.text("选择开始位置") : L10n.text("选择结束位置"),
                          value: endpoint == .start ? startMS : endMS,
                          durationMS: draft.durationMS) { value in
                if endpoint == .start { startMS = value } else { endMS = value }
            }
        }
    }

    private func quote(_ cue: SubtitleCue, endpoint: PlaybackTimeEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(endpoint == .start ? L10n.text("从") : L10n.text("到")).font(.caption).foregroundStyle(.secondary)
            Text(cue.text).font(.body).lineLimit(4)
            if let translation = cue.translatedText, !translation.isEmpty {
                Text(translation).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
            }
        }
        .accessibilityIdentifier(endpoint == .start ? "subtitleClipFirstQuote" : "subtitleClipLastQuote")
    }

    private func timeButton(_ endpoint: PlaybackTimeEndpoint, milliseconds: Int) -> some View {
        Button { editingTime = endpoint } label: {
            VStack(spacing: 8) {
                Text(endpoint == .start ? L10n.text("开始") : L10n.text("结束")).font(.caption).foregroundStyle(.secondary)
                Text(SubtitleTime.clockWithMilliseconds(milliseconds))
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.6).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(endpoint == .start ? "subtitleClipStartTime" : "subtitleClipEndTime")
    }

    private func save() {
        guard validRange, let groupID, !saving else { return }
        let from = startMS, to = endMS
        saving = true
        errorMessage = nil
        Task { @MainActor in
            defer { saving = false }
            do {
                try await store.saveClip(draft.item, startMS: from, endMS: to, groupID: groupID)
                onSaved()
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

enum PlaybackTimeEndpoint: String, Identifiable { case start, end; var id: String { rawValue } }

struct PlaybackTimeWheel: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let durationMS: Int?
    let range: ClosedRange<Int>
    let onSelect: (Int) -> Void
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var milliseconds: Int
    private var value: Int { minutes * 60_000 + seconds * 1_000 + milliseconds }

    init(title: String, value: Int, durationMS: Int?, allowedRange: ClosedRange<Int>? = nil,
         onSelect: @escaping (Int) -> Void) {
        self.title = title
        self.durationMS = durationMS
        let range = allowedRange ?? 0...max(0, durationMS ?? value)
        self.range = range
        self.onSelect = onSelect
        let initial = min(max(value, range.lowerBound), range.upperBound)
        _minutes = State(initialValue: initial / 60_000)
        _seconds = State(initialValue: initial / 1_000 % 60)
        _milliseconds = State(initialValue: initial % 1_000)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    column(L10n.text("分"), selection: $minutes, values: 0...max(0, range.upperBound / 60_000), digits: 2)
                    Text(":").font(.title2)
                    column(L10n.text("秒"), selection: $seconds, values: 0...59, digits: 2)
                    Text(".").font(.title2)
                    column(L10n.text("毫秒"), selection: $milliseconds, values: 0...999, digits: 3)
                }
                .frame(maxWidth: 460)
                if let durationMS {
                    Text("音频全长 \(SubtitleTime.clockWithMilliseconds(durationMS))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !range.contains(value) {
                    Text("可选范围 \(SubtitleTime.clockWithMilliseconds(range.lowerBound)) – \(SubtitleTime.clockWithMilliseconds(range.upperBound))")
                        .font(.caption).foregroundStyle(.red)
                }
                Button("选择") { onSelect(value); dismiss() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!range.contains(value))
                    .accessibilityIdentifier("applyClipTime")
            }
            .padding(20)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .presentationDetents([.height(380)])
    }

    private func column(_ title: String, selection: Binding<Int>, values: ClosedRange<Int>, digits: Int) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { number in Text(String(format: "%0*d", digits, number)).tag(number) }
            }
            .pickerStyle(.wheel)
            .accessibilityIdentifier("clipTimeWheel-\(title)")
            .frame(minWidth: 0, maxWidth: .infinity).clipped()
        }
    }
}
