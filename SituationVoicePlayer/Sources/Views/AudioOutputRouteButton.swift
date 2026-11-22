import SwiftUI
import AVKit

/// The system picker owns route discovery and selection; this control never
/// changes the playback category or requests microphone access.
struct AudioOutputRouteButton: View {
    let outputName: String
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 5 : 9) {
            SystemAudioOutputRoutePicker(outputName: outputName)
                .frame(width: compact ? 48 : 60, height: compact ? 48 : 60)
                .background {
                    Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                        .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 0.5))
                }
                .overlay {
                    // iOS exposes tint customization, but no custom picker image.
                    // Keep the native control as the real touch/accessibility target.
                    Image(systemName: "speaker.wave.2.fill")
                        .font(compact ? .title3 : .title2)
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            Text(outputName).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                .accessibilityIdentifier("callAudioOutputName")
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct SystemAudioOutputRoutePicker: UIViewRepresentable {
    let outputName: String

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .clear
        view.activeTintColor = .clear
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "callAudioOutputButton"
        view.accessibilityLabel = L10n.text("切换音频输出")
        view.accessibilityHint = L10n.text("选择系统提供的音频输出设备")
        view.accessibilityValue = outputName
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.accessibilityValue = outputName
    }
}
