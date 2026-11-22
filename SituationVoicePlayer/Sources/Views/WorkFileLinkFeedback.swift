import SwiftUI

/// Shared, cached probing for visible cards/details; no work data is changed.
private struct WorkFileLinkFeedback<Content: View>: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    @ObservedObject var cache: WorkFileLinkStatusCache
    @ViewBuilder let content: (Bool) -> Content
    @State private var missing = false
    private struct Revision: Hashable {
        let workID: Int64
        let sourceID: Int64
        let content: UInt
        let refresh: UInt
    }
    var body: some View {
        // The initial content is empty. Keep a mounted view for the probe's
        // lifetime so showing the warning cannot depend on it already existing.
        ZStack(alignment: .leading) {
            Color.clear.frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            content(missing)
        }
            .task(id: Revision(workID: work.id, sourceID: work.sourceID,
                              content: store.contentRevision, refresh: cache.refreshRevision)) {
                missing = false
                let result = await cache.result(for: work, store: store)
                guard !Task.isCancelled else { return }
                missing = result == .missing
            }
    }
}

struct WorkFileLinkBadge: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    var body: some View {
        WorkFileLinkFeedback(work: work, store: store, cache: store.fileLinkStatus) { missing in
            if missing {
                Image(systemName: "link")
                    .symbolRenderingMode(.monochrome)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .overlay {
                        Rectangle().fill(AppTheme.groupedCard).frame(width: 4, height: 17)
                            .overlay { Rectangle().fill(AppTheme.secondary).frame(width: 1.5) }
                            .rotationEffect(.degrees(40))
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("本地文件链接失败")
                    .accessibilityIdentifier("workFileLinkFailure-\(work.id)")
            }
        }
        .allowsHitTesting(false)
    }
}

struct WorkFileLinkNotice: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    let relink: () -> Void
    var body: some View {
        WorkFileLinkFeedback(work: work, store: store, cache: store.fileLinkStatus) { missing in
            if missing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本地文件链接失败，请查看本地文件位置。")
                        .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("workFileLinkFailureMessage")
                    Button("重新关联文件", systemImage: "link", action: relink)
                        .font(.footnote)
                        .accessibilityIdentifier("workFileLinkRelink")
                }
            }
        }
    }
}
