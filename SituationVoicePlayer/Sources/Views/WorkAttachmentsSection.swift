import SwiftUI

/// Videos enter the formal queue; reading attachments keep their document readers.
struct WorkAttachmentRowView: View {
    let record: WorkAttachmentRecord
    let work: WorkRecord
    let store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var preview: AttachmentPreview?
    @State private var videoPreview: WorkVideoPreviewController?
    @State private var confirmRemoval = false
    @State private var errorMessage: String?

    private struct AttachmentPreview: Identifiable {
        let id = UUID()
        let url: URL
        let lease: WorkAttachmentDirectoryLease
    }

    var body: some View {
        let file = record.attachment
        Button {
            if file.kind == .video {
                let items = store.queueItems(for: work)
                guard let index = items.firstIndex(where: { $0.attachmentID == record.id }) else { return }
                player.play(items: items, startingAt: index)
                player.isPlayerSheetPresented = true
                return
            }
            do {
                let opened = try store.openAttachment(record, in: work)
                if file.kind == .video { videoPreview = WorkVideoPreviewController(url: opened.url, playback: player) }
                preview = AttachmentPreview(url: opened.url, lease: opened.lease)
            } catch { errorMessage = error.localizedDescription }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.kind.iconName).frame(width: 28).foregroundStyle(AppTheme.textStyle(.tint, AppTheme.emphasisIcon))
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName).font(.subheadline).foregroundStyle(AppTheme.primaryText).lineLimit(2)
                    Text("\(file.kind.title) · \(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))")
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    if file.relativePath != file.fileName {
                        Text(file.relativePath).font(.caption2).lineLimit(1).truncationMode(.middle).foregroundStyle(AppTheme.secondaryText)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.tertiaryText)
            }
        }
        .accessibilityIdentifier("attachment-\(file.relativePath)")
        .contextMenu {
            Button("从作品移除", systemImage: "trash", role: .destructive) { confirmRemoval = true }
        }
        .alert("从作品移除「\(file.fileName)」？", isPresented: $confirmRemoval) {
            Button("移除附件", role: .destructive) {
                do { try store.removeAttachment(record, in: work) }
                catch { errorMessage = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("保留文件 App 中的原文件。") }
        .sheet(item: $preview, onDismiss: {
            videoPreview?.close()
            videoPreview = nil
        }) { opened in
            WorkAttachmentPreviewSheet(attachment: file, attachmentID: record.id,
                readingPositions: store.readingPositions, url: opened.url, lease: opened.lease, videoPreview: videoPreview)
        }
        .alert("附件操作失败", isPresented: Binding(get: { errorMessage != nil },
               set: { if !$0 { errorMessage = nil } })) { Button("好") {} } message: { Text(errorMessage ?? "") }
    }
}
