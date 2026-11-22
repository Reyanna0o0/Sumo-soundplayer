import SwiftUI

/// A presentation-only snapshot of the current timed cue. Source text and its
/// internal line breaks remain untouched; display choices never edit the cue.
struct CallSubtitleContent: Equatable {
    enum Identity: Hashable {
        case cue(UUID)
        case placeholder(String)
    }

    let identity: Identity
    let cueIndex: Int?
    let original: String?
    let translation: String?
    let placeholder: String?

    init(cue: SubtitleCue?, hasTimedCues: Bool, style: SubtitleStyle) {
        let timedCue = cue.flatMap { $0.hasTiming ? $0 : nil }
        cueIndex = timedCue?.index
        if !style.showOriginal && !style.showTranslation {
            original = nil
            translation = nil
            placeholder = L10n.text("字幕已隐藏")
        } else if let timedCue {
            original = style.showOriginal ? Self.nonblank(timedCue.text) : nil
            translation = style.showTranslation ? Self.nonblank(timedCue.translatedText) : nil
            placeholder = original == nil && translation == nil
                ? (style.showOriginal ? "…" : L10n.text("本句暂无译文")) : nil
        } else {
            original = nil
            translation = nil
            placeholder = hasTimedCues ? "…" : L10n.text("暂无定时字幕")
        }
        identity = timedCue.map { .cue($0.id) } ?? .placeholder(placeholder ?? "…")
    }

    private static func nonblank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// Uses its natural height for short cues and an internal scroll viewport for
/// longer ones. Both the explicit limit and the parent's finite height proposal
/// apply to the whole block, including padding; no measured height is published
/// asynchronously back into the surrounding call controls.
struct CallSubtitleText: View {
    let content: CallSubtitleContent
    let fontSize: Double
    var maximumHeight: CGFloat = .infinity

    var body: some View {
        CallSubtitleViewportLayout(maximumHeight: maximumHeight) {
            paragraphs
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            ScrollView(.vertical) {
                paragraphs
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("通话字幕")
            .accessibilityValue(content.cueIndex.map { L10n.text("第 \($0 + 1) 句") } ?? "")
            .accessibilityIdentifier("callSubtitleViewport")
            // Replacing the actual scroll view resets offset synchronously when
            // the cue changes. The same cue keeps its offset during style edits.
            .id(content.identity)
        }
    }

    private var paragraphs: some View {
        VStack(spacing: 6) {
            if let original = content.original {
                Text(original)
                    .accessibilityIdentifier("callSubtitleOriginal")
            }
            if let translation = content.translation {
                Text(translation)
                    .accessibilityIdentifier("callSubtitleTranslation")
            }
            if let placeholder = content.placeholder {
                Text(placeholder)
                    .accessibilityIdentifier("callSubtitlePlaceholder")
            }
        }
        .font(.system(size: fontSize, weight: .medium))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .lineLimit(nil)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
    }
}

private struct CallSubtitleViewportLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let measurement = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let natural = measurement.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let limit = min(heightLimit(maximumHeight), heightLimit(proposal.height))
        return CGSize(width: width ?? natural.width, height: min(natural.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        // The first child exists only for synchronous natural-size measurement.
        // Only the real scroll view participates in display and interaction.
        subviews[1].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func heightLimit(_ value: CGFloat?) -> CGFloat {
        guard let value else { return .infinity }
        return value.isNaN ? 0 : max(0, value)
    }
}
