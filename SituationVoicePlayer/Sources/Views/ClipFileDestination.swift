import SwiftUI
import UIKit

/// 系统文件选择器复制临时导出文件；取消或保存都不移动、删除库内原件。
struct ClipFileDestination: UIViewControllerRepresentable {
    let export: SavedClipFileExport
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(export: export, onClose: onClose) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [export.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        // 文件选择器结束前一直持有，不能因 SwiftUI 更新提前清理临时副本。
        let export: SavedClipFileExport
        let onClose: () -> Void
        init(export: SavedClipFileExport, onClose: @escaping () -> Void) {
            self.export = export; self.onClose = onClose
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish() }
        private func finish() {
            export.removeTemporaryCopy()
            onClose()
        }
    }
}
