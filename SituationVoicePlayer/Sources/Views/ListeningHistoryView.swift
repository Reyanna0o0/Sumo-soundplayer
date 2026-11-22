import SwiftUI

struct ListeningHistoryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    let period: StatPeriod
    @State private var entries: [ListeningHistoryEntry] = []
    @State private var limit = 50
    @State private var hasMore = false
    @State private var readError: String?
    @State private var visible = false

    var body: some View {
        AppList {
            if let readError {
                Section {
                    Text(readError)
                    Button("重试", action: load)
                }
            } else if entries.isEmpty {
                ContentUnavailableView("这段时间没有开始的收听", systemImage: "clock")
            } else {
                Section {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline) {
                                if entry.isSavedClip { Image(systemName: "scissors").accessibilityLabel("摘选") }
                                Text(entry.trackTitle).font(.headline)
                                Spacer(minLength: 8)
                                Text(listeningDuration(entry.seconds)).font(.subheadline.monospacedDigit())
                            }
                            if !entry.workTitle.isEmpty {
                                Text(entry.workTitle).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
                            }
                            Text(startLabel(entry)).font(.caption).foregroundStyle(AppTheme.secondaryText)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("listeningHistoryRow")
                    }
                    if hasMore {
                        Button("显示更早的记录") { limit += 50; load() }
                    }
                } header: {
                    Text(period.displayName + L10n.text(" · 按开始时间排列"))
                }
            }
        }
        .appNavigationColors().navigationTitle(L10n.text("收听明细"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { visible = true; load() }
        .onDisappear { visible = false }
        .onChange(of: store.statsRevision) { load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { load() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in load() }
    }

    private func startLabel(_ entry: ListeningHistoryEntry) -> String {
        let zone = TimeZone(identifier: entry.startTimeZoneID) ?? .current
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = zone
        return entry.startedAt.formatted(style)
    }

    private func load() {
        guard visible && scenePhase == .active else { return }
        do {
            let rows = try store.listeningHistory(period: period, limit: limit + 1)
            entries = Array(rows.prefix(limit))
            hasMore = rows.count > limit
            readError = nil
        } catch { readError = error.localizedDescription }
    }
}
