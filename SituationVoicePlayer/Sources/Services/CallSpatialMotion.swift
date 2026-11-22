import UIKit
import CoreMotion
import simd

/// A single sensor session shared by visible call/preview surfaces. No audio or playback control.
@MainActor
final class CallSpatialMotion {
    static let shared = CallSpatialMotion()
    private let manager = CMMotionManager()
    private var listeners: [UUID: () -> Void] = [:]
    private var reference: simd_quatd?
    private var filtered = CGPoint.zero
    private var published = CGPoint.zero
    private var observer: NSObjectProtocol?
    private var orientation: UIInterfaceOrientation?
    var pose: CGPoint { published }
    var isRunning: Bool { manager.isDeviceMotionActive }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            }
    }

    func observe(_ id: UUID, onChange: @escaping () -> Void) {
        guard UIApplication.shared.applicationState == .active, !UIAccessibility.isReduceMotionEnabled,
              manager.isDeviceMotionAvailable else { release(id); return }
        listeners[id] = onChange
        guard !manager.isDeviceMotionActive else { return }
        reference = nil; filtered = .zero; published = .zero
        manager.deviceMotionUpdateInterval = 1 / 30
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            MainActor.assumeIsolated {
                guard let self, let motion else { return }
                self.receive(motion)
            }
        }
    }

    func release(_ id: UUID) {
        listeners.removeValue(forKey: id)
        if listeners.isEmpty { manager.stopDeviceMotionUpdates(); reference = nil; filtered = .zero; published = .zero }
    }

    private func suspend() {
        manager.stopDeviceMotionUpdates(); reference = nil; filtered = .zero; published = .zero
        let callbacks = Array(listeners.values); listeners.removeAll()
        callbacks.forEach { $0() }
    }

    private func receive(_ motion: CMDeviceMotion) {
        guard UIApplication.shared.applicationState == .active, !UIAccessibility.isReduceMotionEnabled else { suspend(); return }
        let currentOrientation = (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.interfaceOrientation
        if currentOrientation != orientation { orientation = currentOrientation; reference = nil; filtered = .zero }
        let q = motion.attitude.quaternion
        let attitude = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
        if reference == nil { reference = attitude }
        let delta = reference!.inverse * attitude
        let normal = delta.act(SIMD3<Double>(0, 0, 1))
        var x = normal.x / sin(14 * .pi / 180), y = -normal.y / sin(14 * .pi / 180)
        switch currentOrientation {
        case .landscapeLeft: (x, y) = (-y, x)
        case .landscapeRight: (x, y) = (y, -x)
        case .portraitUpsideDown: (x, y) = (-x, -y)
        default: break
        }
        x = x.isFinite ? min(1, max(-1, x)) : 0; y = y.isFinite ? min(1, max(-1, y)) : 0
        filtered.x += (x - filtered.x) * 0.16; filtered.y += (y - filtered.y) * 0.16
        // A continuous quiet zone suppresses hand tremor without jumping at its boundary.
        func settled(_ value: CGFloat) -> CGFloat {
            let magnitude = max(0, abs(value) - 0.025) / (1 - 0.025)
            return value < 0 ? -magnitude : magnitude
        }
        let next = CGPoint(x: settled(filtered.x), y: settled(filtered.y))
        guard hypot(next.x - published.x, next.y - published.y) >= 0.003 else { return }
        published = next
        Array(listeners.values).forEach { $0() }
    }
}
