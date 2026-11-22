import SwiftUI

/// 点卡片播放；作品信息与管理统一放在独立的更多菜单，长按留给外层排序拖动。
struct PersonalWorkCardView: View {
    let work: WorkRecord
    @ObservedObject var store: LibraryStore
    var accessibilityID: String? = nil
    let onShowDetails: () -> Void
    var onRemove: (() -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil

    @EnvironmentObject private var player: PlayerController
    @Environment(\.presentPersonalWorkEditor) private var presentEditor
    @State private var playbackMessage: String?

    private var currentWork: WorkRecord {
        store.works.first { $0.id == work.id }
            ?? store.favoriteWorks.first { $0.id == work.id }
            ?? work
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: play) {
                PersonalWorkRow(work: currentWork, store: store)
                    .padding(.leading, 16)
                    .padding(.trailing, 13)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(accessibilityID ?? "personalWork-\(work.id)")
            .accessibilityHint("播放这部作品；更多菜单可查看作品信息、字幕与附件")

            VStack(spacing: 8) {
                Menu { actions } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.textStyle(.primary.opacity(0.82), AppTheme.ink.opacity(0.82)))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .tint(AppTheme.ink)
                .accessibilityLabel("作品菜单：\(currentWork.title)")
                .accessibilityIdentifier("personalWorkMenu-\(work.id)")
                .menuOrder(.fixed)
                WorkFileLinkBadge(work: currentWork, store: store)
            }
            .padding(.vertical, 8).padding(.trailing, 8)
        }
        .frame(minHeight: 116, alignment: .topLeading)
        .background(AppTheme.groupedCard, in: RoundedRectangle(cornerRadius: 14))
        .alert("无法播放作品", isPresented: Binding(
            get: { playbackMessage != nil }, set: { if !$0 { playbackMessage = nil } }
        )) {
            Button("查看作品资料", action: onShowDetails)
            Button("好", role: .cancel) { playbackMessage = nil }
        } message: {
            Text(playbackMessage ?? "")
        }
    }

    @ViewBuilder private var actions: some View {
        Button(action: onShowDetails) {
            Label("作品信息、字幕与附件", systemImage: "info.circle")
        }
        .accessibilityIdentifier("personalWorkDetails-\(work.id)")
        Button { presentEditor(currentWork, .metadata) } label: { Label("编辑作品资料", systemImage: "pencil") }
            .accessibilityIdentifier("personalEditMetadata-\(work.id)")
        Button { presentEditor(currentWork, .relink) } label: { Label("重新关联文件", systemImage: "link") }
            .accessibilityIdentifier("personalRelinkFiles-\(work.id)")
        Button { presentEditor(currentWork, .script) } label: { Label("导入作品台本", systemImage: "doc.text") }
            .accessibilityIdentifier("personalImportScript-\(work.id)")
        Divider()
        Button { presentEditor(currentWork, .favorite) } label: {
            Label(currentWork.favorite ? L10n.text("管理收藏") : L10n.text("收藏作品"), systemImage: currentWork.favorite ? "heart.fill" : "heart")
        }
        .accessibilityIdentifier("personalWorkFavorite-\(work.id)")
        if let onRemove {
            Button(role: .destructive, action: onRemove) {
                Label("从库中移除", systemImage: "trash")
            }
        }
        if onMoveUp != nil || onMoveDown != nil {
            Divider()
            if let onMoveUp {
                Button("上移作品", systemImage: "arrow.up", action: onMoveUp)
                    .accessibilityIdentifier("personalWorkMoveUp-\(work.id)")
            }
            if let onMoveDown {
                Button("下移作品", systemImage: "arrow.down", action: onMoveDown)
                    .accessibilityIdentifier("personalWorkMoveDown-\(work.id)")
            }
        }
    }

    private func play() {
        let items = store.queueItems(for: currentWork)
        guard !items.isEmpty else {
            playbackMessage = L10n.text("没有找到可播放的文件。可在作品详情中检查音频，或重新关联移动、改名后的文件。")
            return
        }
        // Keep every media item and the work's saved ordering. Audio remains the primary entry point.
        let index = items.firstIndex { !$0.isVideo } ?? items.startIndex
        player.play(items: items, startingAt: index)
        guard player.currentItem?.workID == work.id else {
            playbackMessage = player.errorMessage ?? L10n.text("未能播放这部作品，请在作品详情中检查文件。")
            return
        }
        player.isPlayerSheetPresented = true
    }
}
