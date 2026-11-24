import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Only a temporary share artifact. No library file, preference, or statistic is
/// changed; the activity controller retains this lease until it has finished.
final class ListeningReportImageFile: Identifiable {
    let id = UUID()
    let url: URL
    private let directory: URL

    init(url: URL, directory: URL) { self.url = url; self.directory = directory }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class ListeningReportImageExport: ObservableObject {
    @Published private(set) var progress: Int?
    @Published var file: ListeningReportImageFile?
    @Published var error: String?
    @Published var sharingError: String?
    private var pendingSharingError: String?
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    var isBusy: Bool { progress != nil }

    func start(report: ReviewSnapshot, soundRanking: ListeningRanking, store: LibraryStore) {
        guard !isBusy, file == nil else { return }
        let request = UUID()
        requestID = request
        progress = 0
        error = nil
        sharingError = nil
        pendingSharingError = nil
        task = Task { [weak self] in
            do {
                let result = try await ListeningReportImageRenderer.render(
                    report: report, soundRanking: soundRanking, store: store,
                    progress: { [weak self] page in
                        guard self?.requestID == request else { return }
                        self?.progress = page
                    })
                guard let self, self.requestID == request, !Task.isCancelled else { return }
                self.file = result
                self.progress = nil
                self.task = nil
                self.requestID = nil
            } catch {
                guard let self, self.requestID == request else { return }
                self.progress = nil
                self.task = nil
                self.requestID = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
        progress = nil
    }

    /// Dismiss the system share controller first; its onDismiss presents any
    /// failure afterward. Cancel/success return no error and stay quiet.
    func sharingFinished(fileID: UUID, error: Error?) {
        guard file?.id == fileID else { return }
        pendingSharingError = error?.localizedDescription
        file = nil
    }

    func sharingDismissed() {
        sharingError = pendingSharingError
        pendingSharingError = nil
    }

    deinit { task?.cancel() }
}

enum ListeningReportImageError: LocalizedError {
    case rendering, encoding
    var errorDescription: String? {
        switch self {
        case .rendering: L10n.text("未能绘制报告长图，请稍后重试。")
        case .encoding: L10n.text("未能保存报告长图，请检查可用空间后重试。")
        }
    }
}

@MainActor
enum ListeningReportImageRenderer {
    static let reportWidth: CGFloat = 428
    static let scale: CGFloat = 2

    static func ranking(on page: Int, report: ReviewSnapshot, soundRanking: ListeningRanking) -> ListeningRanking? {
        if page == 2 { return .works }
        guard page == 3 else { return nil }
        if report.scope == .personal { return .creators }
        return soundRanking == .circles ? .circles : .voices
    }

    static func render(report: ReviewSnapshot, soundRanking: ListeningRanking,
                       store: LibraryStore, progress: (Int) -> Void = { _ in }) async throws -> ListeningReportImageFile {
        try Task.checkCancellation()
        let selectedRanking = ranking(on: 3, report: report, soundRanking: soundRanking) ?? .voices
        // Preload only the visible ranking rows, respecting the same privacy
        // preference as the story. The long image contains the same ranking limits.
        let obscured = UserDefaults.standard.bool(forKey: CoverPrivacy.settingKey)
        var images: [String: UIImage] = [:]
        for (index, rank) in [ListeningRanking.works, selectedRanking].enumerated() {
            for entry in (report.ranks[rank] ?? []).prefix(report.kind.previewLimit(for: rank)) {
                let path: String?
                if rank == .works, let id = entry.workID {
                    path = store.coverPath(forWorkID: id)
                } else if let attribution = entry.attribution, case .creator(let id) = attribution,
                          let creator = store.creator(id: id) {
                    path = store.creatorAvatarPath(creator)
                } else { path = nil }
                if let path {
                    images[rank.rawValue + "|" + entry.id] = await CoverCache.shared.image(at: path, maxPixels: 144, obscured: obscured)
                }
                try Task.checkCancellation()
            }
            progress(index + 1)
            await Task.yield()
        }
        try Task.checkCancellation()
        // Render one purpose-built, continuous layout. Its height follows the
        // visible rows instead of concatenating four full-screen page bitmaps.
        let image: CGImage = try autoreleasepool {
            let renderer = ImageRenderer(content:
                ListeningReportStory(report: report, page: .constant(0),
                                     animatesArtwork: false, playsSequence: false,
                                     onClose: {}, onDone: {}, onShowRanking: { _ in },
                                     exportsLongImage: true, exportSoundRanking: selectedRanking, exportImages: images)
                    .environmentObject(store)
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, AppLanguageSelection.shared.locale)
                    .dynamicTypeSize(.large))
            renderer.scale = scale
            renderer.isOpaque = true
            guard let rendered = renderer.cgImage,
                  rendered.width == Int(reportWidth * scale), rendered.height > 0
            else { throw ListeningReportImageError.rendering }
            return rendered
        }
        progress(3)
        await Task.yield()
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListeningReport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(report.title + " · " + report.scope.displayName + ".png")
        do {
            try autoreleasepool {
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { throw ListeningReportImageError.encoding }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ListeningReportImageError.encoding }
            }
            try Task.checkCancellation()
            progress(4)
            return ListeningReportImageFile(url: url, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct ListeningReportImageShareSheet: UIViewControllerRepresentable {
    let file: ListeningReportImageFile
    let onFinish: (Error?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(file: file, onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIActivityViewController {
        makeActivityController(coordinator: context.coordinator)
    }

    func makeActivityController(coordinator: Coordinator) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        controller.completionWithItemsHandler = { [coordinator] _, _, _, error in
            coordinator.onFinish(error)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    final class Coordinator {
        let file: ListeningReportImageFile
        let onFinish: (Error?) -> Void
        init(file: ListeningReportImageFile, onFinish: @escaping (Error?) -> Void) {
            self.file = file; self.onFinish = onFinish
        }
    }
}
