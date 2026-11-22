import SwiftUI
import QuickLook
import AVKit

struct WorkAttachmentPreviewSheet: View {
    let attachment: WorkAttachment
    let attachmentID: Int64
    let readingPositions: ReadingPositionRepository?
    let url: URL
    /// 预览期间保留源目录授权，包括 Quick Look 和系统分享正在读取时。
    let lease: WorkAttachmentDirectoryLease
    var videoPreview: WorkVideoPreviewController? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch attachment.kind {
                case .text:
                    WorkAttachmentTextView(url: url, attachmentID: attachmentID, readingPositions: readingPositions)
                        .appPageBackground(.clear)
                case .pdf:
                    WorkAttachmentPDFReader(url: url, attachmentID: attachmentID, repository: readingPositions)
                case .video:
                    if let videoPreview { WorkAttachmentVideoView(controller: videoPreview) }
                case .image, .document:
                    if QLPreviewController.canPreview(url as NSURL) {
                        WorkAttachmentQuickLook(url: url)
                    } else {
                        ContentUnavailableView("系统无法预览这个文件", systemImage: attachment.kind.iconName,
                                               description: Text("可通过分享按钮在支持此格式的 App 中打开。"))
                            .accessibilityIdentifier("attachmentPreviewError")
                    }
                }
            }
            .navigationTitle(attachment.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("closeAttachment")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("分享附件")
                        .accessibilityIdentifier("shareAttachment")
                }
            }
        }
    }
}

private struct WorkAttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.view.accessibilityIdentifier = "attachmentQuickLook"
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct WorkAttachmentTextView: View {
    let url: URL
    let attachmentID: Int64
    let readingPositions: ReadingPositionRepository?
    @State private var encoding = WorkAttachmentTextEncoding.automatic
    @State private var text: String?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文字编码").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Picker("文字编码", selection: $encoding) {
                    ForEach(WorkAttachmentTextEncoding.allCases) { encoding in
                        Text(encoding.title).tag(encoding)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("attachmentTextEncoding")
            }
            .padding(.horizontal)
            Divider()
            if isLoading {
                ProgressView("正在读取文字…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("无法读取文字", systemImage: "doc.text",
                                       description: Text(errorMessage))
            } else if let text, !text.isEmpty {
                WorkAttachmentTextReaderView(text: text, attachmentID: attachmentID, repository: readingPositions)
            } else {
                ContentUnavailableView("这个文件没有文字", systemImage: "doc.text")
            }
        }
        .task(id: encoding) {
            isLoading = true
            errorMessage = nil
            let selectedEncoding = encoding
            let read = Task.detached(priority: .userInitiated) {
                try WorkAttachmentTextReader.read(from: url, encoding: selectedEncoding)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await read.value
                } onCancel: { read.cancel() }
                try Task.checkCancellation()
                text = result
            } catch is CancellationError {
                return
            } catch {
                text = nil
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct WorkAttachmentVideoView: View {
    @ObservedObject var controller: WorkVideoPreviewController

    var body: some View {
        Group {
            switch controller.state {
            case .loading:
                ProgressView(controller.url.pathExtension.lowercased() == "avi" ? L10n.text("正在准备 AVI 视频…") : L10n.text("正在读取视频…"))
            case .failed(let message):
                ContentUnavailableView {
                    Label("系统无法播放这个视频", systemImage: "play.slash")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { controller.retry() }.accessibilityIdentifier("retryVideoPreview")
                }
                    .accessibilityIdentifier("attachmentPreviewError")
            case .ready:
                if let player = controller.player {
                    WorkVideoPlayerView(player: player)
                    .accessibilityIdentifier("attachmentVideoPlayer")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.updatesNowPlayingInfoCenter = false
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player = nil
    }
}
