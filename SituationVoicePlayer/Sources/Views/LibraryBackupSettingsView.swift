import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LibraryBackupSettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @ObservedObject private var coordinator = LibraryBackupCoordinator.shared
    @State private var showImporter = false
    @State private var exportItem: ExportItem?
    @State private var exportCleanupURL: URL?
    private struct ExportItem: Identifiable { let id = UUID(); let url: URL }
    private func t(_ value: String) -> String { L10n.key(value) }

    var body: some View {
        AppList {
            Section {
                Text(t("备份 App 内的媒体、作品资料、播放位置、字幕、收藏和设置。外部文件夹与 NAS 的音频不复制；新手机需要重新连接来源并输入密码。"))
                    .font(.footnote).foregroundStyle(AppTheme.secondaryText)
                Button(t("导出整库备份"), systemImage: "square.and.arrow.up") {
                    guard prepareOperation() else { return }
                    Task {
                        if let url = await coordinator.export() {
                            exportCleanupURL = url; exportItem = ExportItem(url: url)
                        }
                    }
                }
                Button(t("从备份恢复"), systemImage: "square.and.arrow.down") { showImporter = true }
            } footer: {
                Text(t("备份文件未加密，请保存在可信的位置。导出期间请保持 App 打开。缓存和钥匙串密码不包含在备份中。"))
            }
            if let message = coordinator.message {
                Section { Text(message).font(.footnote) }
            }
        }
        .appNavigationColors().appPageBackground().navigationTitle(t("整库备份与恢复"))
        .disabled(coordinator.isBusy || coordinator.restoreReady)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, prepareOperation() else { return }
                Task { await coordinator.prepareRestore(from: url) }
            case .failure(let error): coordinator.report(error.localizedDescription)
            }
        }
        .sheet(item: $exportItem, onDismiss: {
            if let url = exportCleanupURL { coordinator.removeExport(url) }
            exportCleanupURL = nil
        }) { item in
            LibraryBackupExportPicker(url: item.url) {
                exportItem = nil
            }
        }
        .alert(t("确认替换当前媒体库"), isPresented: Binding(
            get: { coordinator.prepared != nil && !coordinator.isBusy },
            set: { _ in })) {
            Button(t("取消"), role: .cancel) { coordinator.discardPrepared() }
            Button(t("准备恢复"), role: .destructive) {
                guard prepareOperation() else { return }
                Task { await coordinator.confirmRestore() }
            }
        } message: {
            if let prepared = coordinator.prepared {
                Text(t("已完整验证备份。确认后请关闭并重新打开 App，届时替换当前资料并保留原库用于失败回滚。") + "\n\n" +
                     ByteCountFormatter.string(fromByteCount: prepared.manifest.totalBytes, countStyle: .file) + " · " +
                     String(prepared.manifest.files.count) + " " + t("个文件") + "\n\n" +
                     t("外部文件夹与 NAS 音频不包含在备份中。恢复后请重新连接；密码不会恢复。"))
            }
        }
    }
    private func prepareOperation() -> Bool {
        guard !store.phase.isBusy else { coordinator.report("正在导入或保存资料，请完成后再备份或恢复。"); return false }
        player.pause(immediately: true)
        player.flushListeningStatistics()
        return true
    }
}

/// RootView overlays this for the entire operation so edits cannot begin from another tab.
struct LibraryBackupBlockingView: View {
    @ObservedObject private var coordinator = LibraryBackupCoordinator.shared
    private func t(_ value: String) -> String { L10n.key(value) }
    var body: some View {
        VStack(spacing: 20) {
            if coordinator.restoreReady {
                Image(systemName: "arrow.clockwise.circle").font(.largeTitle)
                Text(t("备份已准备好恢复")).font(.title2.bold())
                Text(t("请从 App 切换器关闭厮磨，然后重新打开。重开前当前资料不会被替换，请不要继续编辑媒体库。"))
                Button(t("取消待恢复操作")) { coordinator.cancelPendingRestore() }
            } else {
                ProgressView(value: coordinator.progress).frame(maxWidth: 260)
                Text(t("正在处理备份，请保持 App 打开"))
                Button(t("取消")) { coordinator.cancelOperation() }
            }
        }
        .multilineTextAlignment(.center).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background).foregroundStyle(AppTheme.primaryText).interactiveDismissDisabled()
    }
}

/// Does not instantiate LibraryStore. No live database is opened after a failed launch transaction.
struct LibraryBackupLaunchFailureView: View {
    let message: String
    @State private var resultText: String?
    @State private var recovered = false
    private func t(_ value: String) -> String { L10n.key(value) }
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.shield").font(.largeTitle)
            Text(t("恢复尚未完成")).font(.title2.bold())
            Text(resultText ?? message).font(.body)
            if recovered {
                Text(t("资料已处于安全状态。请关闭并重新打开厮磨以加载媒体库。"))
            } else {
                Button(t("重试恢复或回滚")) {
                    switch LibraryBackupLaunchGate.applyPendingRestoreBeforeAppInitialization() {
                    case .failed(let error): resultText = error
                    default: recovered = true
                    }
                }
                Button(t("取消尚未开始的恢复")) {
                    do {
                        try LibraryBackupLaunchGate.cancelPending(roots: .application()); recovered = true
                    } catch { resultText = error.localizedDescription }
                }
            }
            Text(t("请勿卸载 App。原库和恢复记录仍保存在本机，恢复进行中时不能直接取消。"))
                .font(.footnote).foregroundStyle(AppTheme.secondaryText)
        }.multilineTextAlignment(.center).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.background).foregroundStyle(AppTheme.primaryText)
    }
}

private struct LibraryBackupExportPicker: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finished() }
    }
}
