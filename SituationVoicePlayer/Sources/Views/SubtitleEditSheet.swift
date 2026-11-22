import SwiftUI

/// 编辑单条字幕。开始、结束均以毫秒保存，自动结束只记录用户给的起点。
struct SubtitleEditSheet: View {
    typealias SaveAction = (String, String?, Int?, Int?) -> String?

    let index: Int
    let durationMS: Int?
    let automaticEndFor: (Int) -> Int?
    let onSave: SaveAction
    let onSaveAndNext: SaveAction?
    let playheadMS: Int
    let onDelete: (() -> String?)?
    let onPlayFromHere: (Int) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var translation: String
    @State private var timingEnabled: Bool
    @State private var automaticEnd: Bool
    @State private var startMS: Int
    @State private var manualEndMS: Int?
    @State private var editingTime: PlaybackTimeEndpoint?
    @State private var saveError: String?
    @State private var didAudition = false

    init(index: Int, cue: SubtitleCue, durationMS: Int, playheadMS: Int,
         automaticEndFor: @escaping (Int) -> Int?,
         onSave: @escaping SaveAction,
         onSaveAndNext: SaveAction? = nil,
         onDelete: (() -> String?)?, onPlayFromHere: @escaping (Int) -> String?) {
        self.index = index
        self.playheadMS = playheadMS
        self.durationMS = durationMS > 0 ? durationMS : nil
        self.automaticEndFor = automaticEndFor
        self.onSave = onSave
        self.onSaveAndNext = onSaveAndNext
        self.onDelete = onDelete
        self.onPlayFromHere = onPlayFromHere
        _text = State(initialValue: cue.text)
        _translation = State(initialValue: cue.translatedText ?? "")
        _timingEnabled = State(initialValue: cue.hasTiming)
        _automaticEnd = State(initialValue: !cue.hasTiming || cue.status == .provisional)
        let playhead = max(0, playheadMS)
        let initialStart = durationMS > 0 ? min(playhead, durationMS - 1) : playhead
        _startMS = State(initialValue: cue.hasTiming ? cue.startMS : initialStart)
        _manualEndMS = State(initialValue: cue.hasTiming && cue.status != .provisional ? cue.endMS : nil)
    }

    private var effectiveEnd: Int? { automaticEnd ? automaticEndFor(startMS) : manualEndMS }

    private var validStart: Bool {
        startMS >= 0 && (durationMS.map { startMS < $0 } ?? true)
    }

    private var validRange: Bool {
        guard validStart, let end = effectiveEnd, end > startMS else { return false }
        return durationMS.map { end <= $0 } ?? true
    }

    private var canSave: Bool {
        (!timingEnabled || validRange) && (onDelete != nil ||
            !(text + translation).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// 未得到音频时长时沿用旧编辑器的十小时范围，已有长音频的位置仍可选择。
    private var upperBound: Int { durationMS ?? max(36_000_000, startMS + 1, manualEndMS ?? 0) }

    var body: some View {
        NavigationStack {
            AppForm {
                Section {
                    TextField("原文", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("subtitleDetailText")
                    TextField("译文（可空）", text: $translation, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("subtitleDetailTranslation")
                } header: {
                    Text("第 \(index + 1) 句")
                        .accessibilityIdentifier("subtitleDetailCueNumber")
                } footer: {
                    Text("点「保存」后生效并保留历史版本；取消不保存本次修改。")
                }
                Section {
                    Toggle("设置时间", isOn: $timingEnabled)
                        .accessibilityIdentifier("subtitleTimingEnabled")
                    if timingEnabled {
                        timeButton(.start, value: startMS)
                        Toggle("自动结束", isOn: $automaticEnd)
                            .accessibilityIdentifier("subtitleAutomaticEnd")
                            .onChange(of: automaticEnd) { _, enabled in
                                if !enabled, (manualEndMS ?? 0) <= startMS, let end = automaticEndFor(startMS) {
                                    manualEndMS = end
                                }
                            }
                        if automaticEnd {
                            LabeledContent("预计结束", value: effectiveEnd.map(SubtitleTime.clockWithMilliseconds) ?? L10n.text("请调整开始时间"))
                                .monospacedDigit()
                                .accessibilityIdentifier("subtitleEffectiveEnd")
                        } else {
                            timeButton(.end, value: manualEndMS ?? startMS)
                                .disabled(!validStart)
                        }
                        if !validRange {
                            Text("开始须早于音频结尾，结束须晚于开始并位于音频内。")
                                .font(.caption).foregroundStyle(.red)
                        }
                        HStack(spacing: 8) {
                            ForEach([-500, -100, 100, 500], id: \.self) { delta in
                                Button(String(format: "%@%.1fs", delta < 0 ? "−" : "+", Double(abs(delta)) / 1000)) { nudge(by: delta) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .font(.caption)
                        Button {
                            saveError = onPlayFromHere(startMS)
                            didAudition = saveError == nil
                        } label: {
                            HStack {
                                Label("从这句开始播放", systemImage: "play.circle")
                                if didAudition {
                                    Spacer()
                                    Text(SubtitleTime.clock(playheadMS)).monospacedDigit()
                                        .accessibilityLabel("播放位置")
                                }
                            }
                        }
                        .accessibilityIdentifier("playFromSubtitleCue")
                        .disabled(!validStart)
                    }
                } header: {
                    Text("时间")
                } footer: {
                    if timingEnabled && automaticEnd {
                        Text("播放和导出都用预计结束时间。每句最多显示 5 秒，遇到下一句或音频结尾会提前结束。")
                    } else if !timingEnabled {
                        Text("这句只保存文字。开启后可以选择开始时间。")
                    }
                }
                if let onSaveAndNext {
                    Section {
                        Button("保存并下一句") {
                            save(using: onSaveAndNext, dismissAfterSaving: false)
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("saveSubtitleAndNext")
                    } footer: {
                        Text("保存本句后，按台本顺序打开下一句。下一句原有时间保留；未打轴的句子仍需手动设置时间。")
                    }
                }
                if let onDelete {
                    Section {
                        Button(role: .destructive) {
                            saveError = onDelete()
                            if saveError == nil { dismiss() }
                        } label: {
                            Label("删除这句", systemImage: "trash")
                        }
                    }
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                        .accessibilityIdentifier("subtitleDetailSaveError")
                }
            }
            .accessibilityIdentifier("subtitleDetailForm")
            .appNavigationColors().navigationTitle(L10n.text("编辑字幕"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("cancelSubtitleCue")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save(using: onSave, dismissAfterSaving: true)
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("saveSubtitleCue")
                }
            }
            .sheet(item: $editingTime) { endpoint in
                let isStart = endpoint == .start
                let lower = isStart ? 0 : min(upperBound, startMS + 1)
                let upper = isStart && durationMS != nil ? upperBound - 1 : upperBound
                PlaybackTimeWheel(title: isStart ? L10n.text("选择开始位置") : L10n.text("选择结束位置"),
                                  value: isStart ? startMS : (manualEndMS ?? startMS), durationMS: durationMS,
                                  allowedRange: lower...upper) { value in
                    if isStart { startMS = value } else { manualEndMS = value }
                }
                .appSettingsColorScheme()
            }
        }
        // The fullscreen reader is always dark, while this form uses the
        // selected palette's surfaces. Match semantic text and controls to it.
        .appSettingsColorScheme()
    }

    private func save(using action: SaveAction, dismissAfterSaving: Bool) {
        let start = timingEnabled ? startMS : nil
        let end = timingEnabled && !automaticEnd ? manualEndMS : nil
        saveError = action(text, translation.isEmpty ? nil : translation, start, end)
        if saveError == nil && dismissAfterSaving { dismiss() }
    }

    private func timeButton(_ endpoint: PlaybackTimeEndpoint, value: Int) -> some View {
        Button { editingTime = endpoint } label: {
            HStack {
                Text(endpoint == .start ? L10n.text("开始") : L10n.text("结束"))
                Spacer()
                Text(SubtitleTime.clockWithMilliseconds(value)).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(endpoint == .start ? "subtitleStartTime" : "subtitleEndTime")
    }

    private func nudge(by deltaMS: Int) {
        let maxDelta = automaticEnd ? upperBound - 1 - startMS : upperBound - max(startMS + 1, manualEndMS ?? 0)
        let delta = min(max(deltaMS, -startMS), max(0, maxDelta))
        startMS += delta
        if !automaticEnd, let end = manualEndMS { manualEndMS = end + delta }
    }
}
