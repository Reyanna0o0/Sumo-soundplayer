import SwiftUI
import PDFKit

/// PDFKit keeps the original document selectable and zoomable while giving us a page-space reading anchor.
struct WorkAttachmentPDFReader: View {
    let url: URL
    let attachmentID: Int64
    let repository: ReadingPositionRepository?
    @State private var readError: String?
    @State private var positionError: String?
    @State private var pageDescription = ""
    @State private var positionDescription = ""

    var body: some View {
        VStack(spacing: 0) {
            if let readError {
                ContentUnavailableView("无法打开 PDF", systemImage: "doc.richtext",
                    description: Text(readError))
                    .accessibilityIdentifier("attachmentPreviewError")
            } else {
                RememberingPDFView(url: url, attachmentID: attachmentID, repository: repository,
                    onReadError: { readError = $0 }, onPositionError: { positionError = $0 },
                    onPosition: { position, count in
                        pageDescription = L10n.text("第 \(position.pageIndex + 1) / \(count) 页")
                        #if DEBUG
                        positionDescription = String(format: "page=%ld;x=%.6f;y=%.6f",
                            position.pageIndex, position.x, position.y)
                        #else
                        positionDescription = pageDescription
                        #endif
                    })
                if !pageDescription.isEmpty {
                    Text(pageDescription).font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                        .accessibilityIdentifier("attachmentPDFPage")
                        .accessibilityValue(positionDescription)
                }
            }
            if let positionError {
                Text(positionError).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal).padding(.bottom, 6)
                    .accessibilityIdentifier("readingPositionError")
            }
        }
    }
}

private struct RememberingPDFView: UIViewRepresentable {
    let url: URL
    let attachmentID: Int64
    let repository: ReadingPositionRepository?
    let onReadError: (String) -> Void
    let onPositionError: (String?) -> Void
    let onPosition: (PDFReadingPosition, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReadingPDFView {
        let view = ReadingPDFView()
        view.backgroundColor = .secondarySystemBackground
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.accessibilityIdentifier = "attachmentPDFContent"
        context.coordinator.attach(view, url: url)
        return view
    }

    func updateUIView(_ view: ReadingPDFView, context: Context) {}

    static func dismantleUIView(_ view: ReadingPDFView, coordinator: Coordinator) {
        coordinator.stop()
        view.onSizeChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        // This instance is tied to one attachment ID, so a disappearing old view cannot save into another file.
        private let owner: RememberingPDFView
        private weak var view: ReadingPDFView?
        private var timer: Timer?
        private var restoreTask: Task<Void, Never>?
        private var lastPosition: PDFReadingPosition?
        private var lastSavedPosition: PDFReadingPosition?
        private var isReady = false
        private var didReportUnavailable = false

        init(_ owner: RememberingPDFView) { self.owner = owner }

        func attach(_ view: ReadingPDFView, url: URL) {
            self.view = view
            do {
                lastPosition = try owner.repository?.pdfPosition(attachmentID: owner.attachmentID)
                lastSavedPosition = lastPosition
            } catch { reportPositionFailure() }
            guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
                DispatchQueue.main.async { [owner] in
                    owner.onReadError(L10n.text("文件可能已损坏或需要密码。可通过分享按钮在其他 App 中打开。"))
                }
                return
            }
            view.document = document
            view.onSizeChanged = { [weak self] in self?.restoreAfterLayout() }
            NotificationCenter.default.addObserver(self, selector: #selector(flush),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(flush),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            // PDFKit's page notification alone misses movement within a page; sample only while the reader exists.
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.captureAndSave() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }

        private func restoreAfterLayout() {
            guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let target = lastPosition
            isReady = false
            restoreTask?.cancel()
            restoreTask = Task { [weak self, weak view] in
                // PDFKit lays pages out asynchronously after the SwiftUI host acquires its final size.
                for delay in [40, 100, 180] {
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard self != nil, let view, let document = view.document else { return }
                    if view.isBeingScrolled {
                        self?.isReady = true
                        self?.restoreTask = nil
                        self?.captureAndSave()
                        return
                    }
                    view.layoutIfNeeded()
                    if let target, let index = target.resolvedPageIndex(pageCount: document.pageCount),
                       let page = document.page(at: index) {
                        let box = page.bounds(for: view.displayBox)
                        let point = CGPoint(x: box.minX + CGFloat(target.x) * box.width,
                                            y: box.minY + CGFloat(target.y) * box.height)
                        view.go(to: PDFDestination(page: page, at: point))
                    }
                    // The initial restoration must never save the temporary first-page layout.
                    if Task.isCancelled { return }
                }
                guard let self else { return }
                self.isReady = true
                self.restoreTask = nil
                self.captureAndSave()
            }
        }

        private func visiblePosition() -> PDFReadingPosition? {
            guard let view, let document = view.document,
                  view.bounds.width > 0, view.bounds.height > 0 else { return nil }
            // Select the page touching the top of the viewport, even when the following page occupies its centre.
            let probe = CGPoint(x: view.bounds.midX, y: view.bounds.minY + 1)
            guard let page = view.page(for: probe, nearest: true) else { return nil }
            let index = document.index(for: page)
            let box = page.bounds(for: view.displayBox)
            guard index != NSNotFound, box.width > 0, box.height > 0 else { return nil }
            // PDFDestination places its point at the viewport's origin. Sampling one point below it
            // would move the saved destination by that point on every close/reopen cycle.
            let point = view.convert(CGPoint(x: view.bounds.minX, y: view.bounds.minY), to: page)
            return PDFReadingPosition(pageIndex: index,
                x: Double((point.x - box.minX) / box.width), y: Double((point.y - box.minY) / box.height))
        }

        private func captureAndSave() {
            guard isReady, let position = visiblePosition(), let document = view?.document else { return }
            lastPosition = position
            owner.onPosition(position, document.pageCount)
            guard position != lastSavedPosition else { return }
            guard let repository = owner.repository else {
                if !didReportUnavailable { didReportUnavailable = true; reportPositionFailure() }
                return
            }
            do {
                try repository.savePDFPosition(position, attachmentID: owner.attachmentID)
                lastSavedPosition = position
                owner.onPositionError(nil)
            } catch { reportPositionFailure() }
        }

        private func reportPositionFailure() {
            DispatchQueue.main.async { [owner] in
                owner.onPositionError(L10n.text("阅读位置暂时无法保存，请稍后重新打开。"))
            }
        }

        @objc private func flush() { captureAndSave() }

        func stop() {
            captureAndSave()
            restoreTask?.cancel()
            timer?.invalidate()
            timer = nil
            NotificationCenter.default.removeObserver(self)
        }

        deinit {
            restoreTask?.cancel()
            timer?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class ReadingPDFView: PDFView {
    var onSizeChanged: (() -> Void)?
    private var previousSize = CGSize.zero

    var isBeingScrolled: Bool {
        func interacting(_ view: UIView) -> Bool {
            if let scroll = view as? UIScrollView,
               scroll.isTracking || scroll.isDragging || scroll.isDecelerating { return true }
            return view.subviews.contains(where: interacting)
        }
        return interacting(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != previousSize, bounds.width > 0, bounds.height > 0 else { return }
        previousSize = bounds.size
        onSizeChanged?()
    }
}
