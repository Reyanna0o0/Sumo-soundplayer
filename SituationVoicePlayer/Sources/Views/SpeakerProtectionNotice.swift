import SwiftUI

/// A compact explanation and explicit fallback when a hardware volume button
/// cannot change the system volume (for example, at its upper or lower limit).
struct SpeakerProtectionNotice: View {
    @ObservedObject private var protection = SpeakerProtection.shared

    var body: some View {
        if protection.isMuted && protection.isPlaybackActive {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    noticeLabel.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    allowButton.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 0) {
                    noticeLabel
                    allowButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(AppTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(AppTheme.iconTint.opacity(0.18))
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityIdentifier("speakerProtectionNotice")
        }
    }

    private var noticeLabel: some View {
        Label("外放保护已静音", systemImage: "speaker.slash.fill")
            .accessibilityElement(children: .combine)
    }

    private var allowButton: some View {
        Button("允许本次外放") {
            protection.allowCurrentSpeakerPlayback()
        }
        .fontWeight(.semibold)
        .foregroundStyle(AppTheme.iconTint)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityIdentifier("allowCurrentSpeakerPlayback")
    }
}
