import SwiftUI
import UIKit

/// Keyboard avoidance belongs to the inline reader, not to the page's cover or transport bar.
@MainActor
final class SubtitleInlineKeyboard: ObservableObject {
    enum Part: Hashable { case content, form, original, translation, actions }
    struct Configuration: Equatable {
        var editing: Bool
        var field: Part
        var appliedLift: CGFloat
        var maximumLift: CGFloat
    }
    struct Space: Equatable {
        var visible: CGRect
        var topPadding: CGFloat
        var bottomPadding: CGFloat
        var temporaryLift: CGFloat
    }

    @Published private(set) var topPadding: CGFloat = 0
    @Published private(set) var bottomPadding: CGFloat = 0
    @Published private(set) var temporaryLift: CGFloat = 0
    private var configuration = Configuration(editing: false, field: .original, appliedLift: 0, maximumLift: 0)
    private final class WeakView { weak var value: UIView?; init(_ value: UIView) { self.value = value } }
    private var markers: [Part: WeakView] = [:]
    private var keyboardScreenFrame: CGRect?
    private var observers: [NSObjectProtocol] = []
    private var scheduled = false
    private var needsReveal = false
    private var lastFieldSize = CGSize.zero
    private var mountForm: (() -> Void)?
    private struct MountGeometry: Equatable {
        let viewport: CGSize
        let content: CGSize
        let offset: CGPoint
    }
    private var lastMountGeometry: MountGeometry?
    private var mountRequests = 0

    var hasMountedForm: Bool { markers[.form]?.value?.window != nil }

    init() {
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
                     UIResponder.keyboardWillHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let frame = note.name == UIResponder.keyboardWillHideNotification ? nil
                        : (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                    guard self.keyboardScreenFrame != frame else { return }
                    self.keyboardScreenFrame = frame
                    self.requestUpdate(reveal: true)
                }
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func configure(_ value: Configuration) {
        let changedField = value.field != configuration.field || value.editing != configuration.editing
        configuration = value
        requestUpdate(reveal: changedField)
    }

    /// Lazy rows do not necessarily exist when SwiftUI starts the edit task.
    /// Request their mount after actual viewport/content layout, and again only
    /// when lazy height estimates or the scroll offset have changed.
    func mountFormWhenReady(_ action: @escaping () -> Void) {
        mountForm = action
        lastMountGeometry = nil
        mountRequests = 0
        requestUpdate(reveal: true)
    }

    func cancelFormMount() {
        mountForm = nil
        lastMountGeometry = nil
        mountRequests = 0
    }

    func register(_ view: UIView, as part: Part) {
        markers[part] = WeakView(view)
        requestUpdate(reveal: part == .form)
    }
    func unregister(_ view: UIView, as part: Part) {
        if markers[part]?.value === view { markers.removeValue(forKey: part) }
    }
    func requestUpdate(reveal: Bool = false) {
        needsReveal = needsReveal || reveal
        guard !scheduled else { return }
        scheduled = true
        // UIView layout callbacks can occur during SwiftUI's update. Coalesce them after that pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.update()
        }
    }

    /// All rectangles are in this window's coordinates, including an undocked keyboard.
    /// A low user divider is lifted only enough for one input line and the inline actions.
    static func space(viewport: CGRect, keyboard: CGRect?, field: CGRect, appliedLift: CGFloat,
                      maximumLift: CGFloat, minimumEditingHeight: CGFloat,
                      allowBelowFloatingKeyboard: Bool = false) -> Space {
        let edge: CGFloat = 24 // Keep fields clear of the reader's existing 22-point edge fade.
        let naturalTop = viewport.minY + appliedLift
        let natural = CGRect(x: viewport.minX, y: naturalTop, width: viewport.width,
                             height: max(0, viewport.maxY - naturalTop))
        guard let keyboard, !keyboard.isEmpty, keyboard.maxY > natural.minY,
              keyboard.minY < natural.maxY, keyboard.maxX > field.minX, keyboard.minX < field.maxX else {
            return Space(visible: natural.insetBy(dx: 0, dy: min(edge, natural.height / 2)), topPadding: 0,
                         bottomPadding: 0, temporaryLift: 0)
        }
        let availableAbove = keyboard.minY - natural.minY - edge * 2
        let lift = min(maximumLift, max(0, minimumEditingHeight - availableAbove))
        let top = natural.minY - lift + edge
        let bottom = min(natural.maxY - edge, keyboard.minY - edge)
        let belowTop = max(natural.minY, keyboard.maxY) + edge
        let belowBottom = natural.maxY - edge
        // A high undocked keyboard may leave no usable upper strip. Keep the same reader
        // and use its unobscured lower strip instead; the saved divider is unchanged.
        if allowBelowFloatingKeyboard, bottom - top < minimumEditingHeight,
           belowBottom - belowTop >= minimumEditingHeight || (bottom <= top && belowBottom > belowTop) {
            return Space(visible: CGRect(x: natural.minX, y: belowTop, width: natural.width, height: belowBottom - belowTop),
                         topPadding: max(0, keyboard.maxY - natural.minY), bottomPadding: 0, temporaryLift: 0)
        }
        return Space(visible: CGRect(x: natural.minX, y: top, width: natural.width, height: max(0, bottom - top)),
                     topPadding: 0, bottomPadding: max(0, natural.maxY - keyboard.minY), temporaryLift: lift)
    }

    private func update() {
        if hasMountedForm { cancelFormMount() }
        if configuration.editing, let mountForm, let content = markers[.content]?.value,
           content.window != nil, let scroll = enclosingScroll(content),
           scroll.bounds.width > 0, scroll.bounds.height > 0, scroll.contentSize.height > 0 {
            if scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
                cancelFormMount()
            } else {
                let geometry = MountGeometry(viewport: scroll.bounds.size, content: scroll.contentSize,
                                             offset: scroll.contentOffset)
                if geometry != lastMountGeometry {
                    lastMountGeometry = geometry
                    // Stop an invalid/unresolvable target from causing an unbounded layout cycle.
                    if mountRequests < 12 {
                        mountRequests += 1
                        mountForm()
                    } else { cancelFormMount() }
                }
            }
        }
        guard configuration.editing, let form = markers[.form]?.value,
              let window = form.window, let scroll = enclosingScroll(form) else {
            setLayout(top: 0, bottom: 0, lift: 0)
            return
        }
        let viewport = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
        let field = markers[configuration.field]?.value ?? form
        let fieldRect = field.convert(field.bounds, to: window)
        let keyboard = keyboardScreenFrame.map { window.convert($0, from: window.screen.coordinateSpace).intersection(window.bounds) }
        let actionsHeight = markers[.actions]?.value?.bounds.height ?? 44
        let minimum = 44 + max(44, actionsHeight) + 16
        let space = Self.space(viewport: viewport, keyboard: keyboard, field: fieldRect,
                               appliedLift: configuration.appliedLift, maximumLift: configuration.maximumLift,
                               minimumEditingHeight: minimum, allowBelowFloatingKeyboard: true)
        if setLayout(top: space.topPadding, bottom: space.bottomPadding, lift: space.temporaryLift) {
            needsReveal = true
            // Padding can change only the content marker, without relaying out the form.
            // Ensure one more post-layout pass even if UIKit sends no form callback.
            requestUpdate(reveal: true)
            return // Re-evaluate after SwiftUI lays out the extra scroll content / temporary divider.
        }
        let sizeChanged = lastFieldSize != field.bounds.size
        lastFieldSize = field.bounds.size
        guard needsReveal || sizeChanged else { return }
        needsReveal = false
        guard !scroll.isTracking, !scroll.isDragging, !scroll.isDecelerating,
              space.visible.height > 1 else { return }
        let formRect = form.convert(form.bounds, to: window)
        var target = formRect.height <= space.visible.height ? formRect : fieldRect
        if target.height > space.visible.height {
            // Long vertical text fields scroll internally. Reveal the insertion point instead of their whole height.
            target = caret(in: window) ?? CGRect(x: fieldRect.minX, y: fieldRect.minY,
                                                 width: fieldRect.width, height: min(44, fieldRect.height))
        }
        let delta: CGFloat
        if target.minY < space.visible.minY { delta = target.minY - space.visible.minY }
        else if target.maxY > space.visible.maxY { delta = target.maxY - space.visible.maxY }
        else { return }
        let minimumOffset = -scroll.adjustedContentInset.top
        let maximumOffset = max(minimumOffset, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        let y = min(max(scroll.contentOffset.y + delta, minimumOffset), maximumOffset)
        if abs(y - scroll.contentOffset.y) > 0.5 {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        }
    }

    @discardableResult private func setLayout(top: CGFloat, bottom: CGFloat, lift: CGFloat) -> Bool {
        var changed = false
        if abs(topPadding - top) > 0.5 { topPadding = top; changed = true }
        if abs(bottomPadding - bottom) > 0.5 { bottomPadding = bottom; changed = true }
        if abs(temporaryLift - lift) > 0.5 { temporaryLift = lift; changed = true }
        return changed
    }

    private func enclosingScroll(_ view: UIView) -> UIScrollView? {
        var ancestor = view.superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }
    private func caret(in view: UIView) -> CGRect? {
        if view.isFirstResponder, let input = view as? any UITextInput, let selected = input.selectedTextRange,
           let window = view.window {
            let rect = input.caretRect(for: selected.end)
            if !rect.isEmpty { return view.convert(rect.insetBy(dx: -2, dy: -4), to: window) }
        }
        for child in view.subviews { if let rect = caret(in: child) { return rect } }
        return nil
    }
}

struct SubtitleKeyboardMarker: UIViewRepresentable {
    let part: SubtitleInlineKeyboard.Part
    let avoidance: SubtitleInlineKeyboard
    final class Marker: UIView {
        weak var avoidance: SubtitleInlineKeyboard?
        override func layoutSubviews() { super.layoutSubviews(); avoidance?.requestUpdate() }
        override func didMoveToWindow() { super.didMoveToWindow(); avoidance?.requestUpdate() }
    }
    final class Coordinator {
        weak var avoidance: SubtitleInlineKeyboard?
        var part: SubtitleInlineKeyboard.Part?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Marker {
        let view = Marker()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }
    func updateUIView(_ view: Marker, context: Context) {
        let coordinator = context.coordinator
        if coordinator.avoidance !== avoidance || coordinator.part != part {
            if let old = coordinator.part { coordinator.avoidance?.unregister(view, as: old) }
            coordinator.avoidance = avoidance; coordinator.part = part
            view.avoidance = avoidance
            avoidance.register(view, as: part)
        }
    }
    static func dismantleUIView(_ view: Marker, coordinator: Coordinator) {
        if let part = coordinator.part { coordinator.avoidance?.unregister(view, as: part) }
    }
}
