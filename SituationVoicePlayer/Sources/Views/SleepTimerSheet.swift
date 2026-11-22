import SwiftUI

struct SleepTimerSheet: View {
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30

    var body: some View {
        NavigationStack {
            AppForm {
                if player.sleepTimer != .off {
                    Section("当前定时") {
                        switch player.sleepTimer {
                        case .deadline:
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let seconds = player.sleepTimer.remainingSeconds(at: .now) ?? 0
                                LabeledContent("剩余时间", value: SubtitleTime.clock(seconds * 1000))
                                    .monospacedDigit()
                            }
                        case .endOfTrack:
                            Label("播完当前音轨就停", systemImage: "moon.fill")
                        case .endOfQueueItem(let id):
                            if let item = player.queue.items.first(where: { $0.id == id }) {
                                LabeledContent("播完后停止", value: item.trackTitle)
                                    .accessibilityIdentifier("sleepSelectedQueueTarget")
                            }
                        case .off:
                            EmptyView()
                        }
                        Button("取消定时", role: .destructive) {
                            player.cancelSleepTimer()
                            dismiss()
                        }
                        .accessibilityIdentifier("cancelSleepTimer")
                    }
                }

                if let notice = player.sleepTimerNotice {
                    Section { Text(notice).font(.footnote).foregroundStyle(AppTheme.secondaryText) }
                }

                Section {
                    Button {
                        player.setSleepTimerForCurrentTrack()
                        dismiss()
                    } label: {
                        Label("播完当前音轨就停", systemImage: "music.note")
                    }
                    .accessibilityIdentifier("sleepEndOfTrack")
                    NavigationLink {
                        SleepQueueTargetPicker { id in
                            player.setSleepTimer(afterQueueItemID: id)
                            dismiss()
                        }
                    } label: {
                        Label("播完指定音轨后停止", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("sleepChooseQueueTarget")
                    .disabled(player.queue.isEmpty)
                }

                Section {
                    HStack {
                        ForEach([15, 30, 45, 60], id: \.self) { value in
                            Button("\(value) 分") { minutes = value }
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderless)

                    HStack {
                        ForEach([120, 360, 720], id: \.self) { value in
                            Button(durationTitle(value)) { minutes = value }
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("sleepPreset-\(value)")
                        }
                    }
                    .buttonStyle(.borderless)

                    Picker("分钟", selection: $minutes) {
                        ForEach(PlaybackSleepTimer.minutesRange, id: \.self) { value in
                            Text(durationTitle(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.wheel)
                    .accessibilityIdentifier("sleepMinutes")

                    Button("\(durationTitle(minutes))后停止") {
                        player.setSleepTimer(minutes: minutes)
                        dismiss()
                    }
                    .accessibilityIdentifier("startSleepMinutes")
                } header: {
                    Text("按时长停止")
                } footer: {
                    Text("最多 12 小时；暂停或锁屏时倒计时继续。")
                }
            }
            .appNavigationColors().navigationTitle(L10n.text("睡眠定时"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func durationTitle(_ minutes: Int) -> String {
        if minutes < 60 { return L10n.text("\(minutes) 分钟") }
        let hours = minutes / 60, remainder = minutes % 60
        return remainder == 0 ? L10n.text("\(hours) 小时") : L10n.text("\(hours) 小时 \(remainder) 分钟")
    }
}

private struct SleepQueueTargetPicker: View {
    @EnvironmentObject private var player: PlayerController
    let select: (UUID) -> Void

    var body: some View {
        AppList {
            Section {
                ForEach(Array(player.queue.order.enumerated().dropFirst(player.queue.cursor)), id: \.element) { position, index in
                    let item = player.queue.items[index]
                    Button { select(item.id) } label: {
                        HStack(spacing: 12) {
                            Text("\(position + 1)").font(.caption).monospacedDigit().foregroundStyle(AppTheme.secondaryText)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.trackTitle).foregroundStyle(AppTheme.primaryText)
                                Text(item.workTitle).font(.caption).foregroundStyle(AppTheme.secondaryText)
                            }
                            Spacer()
                            if item.id == player.currentItem?.id {
                                Image(systemName: "speaker.wave.2.fill").accessibilityLabel("当前音轨")
                            }
                            if item.id == player.sleepTimer.queueTargetID { Image(systemName: "checkmark") }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("sleepQueueTarget-\(index)")
                }
            } footer: {
                Text("按当前队列顺序播放，播完选中的音轨后停止。单曲循环会暂时按队列前进；跳过目标、删除目标或把它拖到当前项之前会取消定时。")
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("播完哪一首后停止"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
