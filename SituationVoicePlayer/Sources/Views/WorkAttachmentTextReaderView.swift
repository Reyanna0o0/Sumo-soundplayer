import SwiftUI
import UIKit

/// Store a text position rather than a pixel offset, so wrapping on another screen width still finds the same passage.
struct WorkAttachmentTextReaderView: View {
    let text: String
    let attachmentID: Int64
    let repository: ReadingPositionRepository?
    @State private var positionError: String?
    @State private var readPercent = 0
    @State private var positionValue = ""

    var body: some View {
        VStack(spacing: 0) {
            RememberingAttachmentText(text: text, attachmentID: attachmentID, repository: repository,
                onError: { positionError = $0 }, onPosition: { offset in
                    readPercent = min(100, max(0, Int(Double(offset) / Double(max(1, text.utf16.count)) * 100)))
                    #if DEBUG
                    positionValue = "offset=\(offset)"
                    #else
                    positionValue = "\(readPercent)%"
                    #endif
                })
            Text("阅读进度 \(readPercent)%").font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                .accessibilityIdentifier("attachmentTextPosition")
                .accessibilityValue(positionValue)
            if let positionError {
                Text(positionError).font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal).padding(.bottom, 6)
                    .accessibilityIdentifier("readingPositionError")
            }
        }
    }
}

/// Use continuous text layout so caret coordinates remain consistent after a width change.
private struct RememberingAttachmentText: UIViewRepresentable {
    let text: String
    let attachmentID: Int64
    let repository: ReadingPositionRepository?
    let onError: (String?) -> Void
    let onPosition: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReadingAttachmentTextView {
        let view = ReadingAttachmentTextView(usingTextLayoutManager: false)
        view.layoutManager.allowsNonContiguousLayout = false
        view.isEditable = false
        view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 24, right: 14)
        view.text = text
        view.accessibilityIdentifier = "attachmentTextContent"
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: ReadingAttachmentTextView, context: Context) {
        view.backgroundColor = AppTheme.isPurple ? .clear : .systemBackground
        if view.text != text { context.coordinator.replaceText(text) }
    }

    static func dismantleUIView(_ view: ReadingAttachmentTextView, coordinator: Coordinator) {
        coordinator.stop()
        view.delegate = nil
        view.onSizeChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private let owner: RememberingAttachmentText
        private weak var view: ReadingAttachmentTextView?
        private var lastPosition: TextReadingPosition?
        private var lastSavedPosition: TextReadingPosition?
        private var restoreTask: Task<Void, Never>?
        private var pendingSave: Task<Void, Never>?
        private var isReady = false
        private var readySize = CGSize.zero
        private var didReportUnavailable = false

        init(_ owner: RememberingAttachmentText) { self.owner = owner }

        func attach(_ view: ReadingAttachmentTextView) {
            self.view = view
            do {
                lastPosition = try owner.repository?.textPosition(attachmentID: owner.attachmentID)
                lastSavedPosition = lastPosition
            } catch { reportFailure() }
            view.delegate = self
            view.onSizeChanged = { [weak self] in self?.restoreAfterLayout() }
            NotificationCenter.default.addObserver(self, selector: #selector(flush),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(flush),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
        }

        func replaceText(_ text: String) {
            captureAndSave()
            isReady = false
            view?.text = text
            restoreAfterLayout()
        }

        private func restoreAfterLayout() {
            guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let target = lastPosition
            isReady = false
            pendingSave?.cancel()
            pendingSave = nil
            restoreTask?.cancel()
            restoreTask = Task { [weak self, weak view] in
                for delay in [30, 80, 120] {
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard let view else { return }
                    view.layoutIfNeeded()
                    guard !Task.isCancelled else { return }
                    if let target {
                        let length = (view.text as NSString).length
                        let offset = target.clampedUTF16Offset(in: view.text)
                        // Measure only through the target character before asking for its caret.
                        view.layoutManager.ensureLayout(forCharacterRange:
                            NSRange(location: 0, length: min(length, offset + 1)))
                        guard !Task.isCancelled else { return }
                        // Bring an off-screen character into view before aligning its line.
                        view.scrollRangeToVisible(NSRange(location: offset, length: min(1, length - offset)))
                        view.layoutIfNeeded()
                        guard !Task.isCancelled else { return }
                        if let position = view.position(from: view.beginningOfDocument, offset: offset) {
                            let rect = view.caretRect(for: position)
                            if rect.minY.isFinite {
                                let minimum = -view.adjustedContentInset.top
                                let maximum = max(minimum, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
                                let y = min(maximum, max(minimum, rect.minY - view.textContainerInset.top))
                                view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
                            }
                        }
                    }
                    guard !Task.isCancelled else { return }
                }
                guard !Task.isCancelled, let self else { return }
                self.readySize = self.view?.bounds.size ?? .zero
                self.isReady = true
                self.restoreTask = nil
                self.captureAndSave()
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // Deliberate reading takes priority over a pending layout retry.
            restoreTask?.cancel()
            restoreTask = nil
            readySize = scrollView.bounds.size
            isReady = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isReady, scrollView.bounds.size == readySize else { return }
            capturePosition()
            // Avoid a database write for every animation frame; exits and backgrounding flush synchronously.
            guard pendingSave == nil else { return }
            pendingSave = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                self.pendingSave = nil
                self.captureAndSave()
            }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { captureAndSave() }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { captureAndSave() }

        private func capturePosition() {
            guard isReady, let view, view.bounds.size == readySize,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            let point = CGPoint(x: view.textContainerInset.left + view.textContainer.lineFragmentPadding,
                // At a line's exact upper edge, TextKit may return the previous line's final character.
                // Sampling the line's middle makes save → restore → save stable instead of creeping upward.
                y: view.contentOffset.y + view.adjustedContentInset.top + view.textContainerInset.top
                    + (view.font?.lineHeight ?? 22) / 2)
            guard let position = view.closestPosition(to: point) else { return }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            lastPosition = TextReadingPosition(utf16Offset: offset)
            owner.onPosition(offset)
        }

        private func captureAndSave() {
            guard isReady else { return }
            capturePosition()
            guard let position = lastPosition, position != lastSavedPosition else { return }
            guard let repository = owner.repository else {
                if !didReportUnavailable { didReportUnavailable = true; reportFailure() }
                return
            }
            do {
                try repository.saveTextPosition(position, attachmentID: owner.attachmentID)
                lastSavedPosition = position
                owner.onError(nil)
            } catch { reportFailure() }
        }

        private func reportFailure() {
            DispatchQueue.main.async { [owner] in
                owner.onError(L10n.text("阅读位置暂时无法保存，请稍后重新打开。"))
            }
        }

        @objc private func flush() { captureAndSave() }

        func stop() {
            captureAndSave()
            pendingSave?.cancel()
            restoreTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        deinit {
            pendingSave?.cancel()
            restoreTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private final class ReadingAttachmentTextView: UITextView {
    var onSizeChanged: (() -> Void)?
    private var previousSize = CGSize.zero

    override func layoutSubviews() {
        if bounds.size != previousSize, bounds.width > 0, bounds.height > 0 {
            previousSize = bounds.size
            // UIKit can change the offset and call didScroll inside its own layout.
            // Freeze the saved passage before those temporary rotation offsets arrive.
            onSizeChanged?()
        }
        super.layoutSubviews()
    }
}
