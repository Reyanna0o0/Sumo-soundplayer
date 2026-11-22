import Combine
import SwiftUI
import UIKit

/// Keep the existing app-wide defaults; narrow only the window scene containing an iPhone call.
@MainActor
final class CallOrientationAppDelegate: NSObject, UIApplicationDelegate {
    // The scene-delegate replacement requires iOS 27. Keep this public compatibility
    // entry point for the app's iOS 18+ range without replacing SwiftUI's scene delegate.
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        CallOrientationPolicy.shared.supportedOrientations(for: window)
    }
}

@MainActor
final class CallOrientationPolicy {
    static let shared = CallOrientationPolicy()

    private final class Registration {
        weak var scene: UIWindowScene?
        weak var window: UIWindow?
        weak var player: PlayerController?
        var observation: AnyCancellable?
        var lastRequestedMask: UIInterfaceOrientationMask?
        var refreshScheduled = false
        var forceRefresh = false

        init(player: PlayerController, window: UIWindow, scene: UIWindowScene) {
            self.player = player; self.window = window; self.scene = scene
        }
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var activeObserver: NSObjectProtocol?

    private init() {
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshActiveScenes() }
        }
    }

    func supportedOrientations(for window: UIWindow?) -> UIInterfaceOrientationMask {
        let idiom = window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom
        guard idiom == .phone else { return .all }
        guard let scene = window?.windowScene,
              let registration = registrations[ObjectIdentifier(scene)],
              registration.player?.isInCall == true else { return .allButUpsideDown }
        return .portrait
    }

    func attach(player: PlayerController, window: UIWindow, forceRefresh: Bool) {
        guard window.traitCollection.userInterfaceIdiom == .phone,
              let scene = window.windowScene else { return }
        let key = ObjectIdentifier(scene)
        if let registration = registrations[key], registration.player === player {
            let changedWindow = registration.window !== window
            registration.window = window
            scheduleRefresh(registration, force: forceRefresh || changedWindow)
            return
        }
        let registration = Registration(player: player, window: window, scene: scene)
        registrations[key] = registration
        // Keep observing when Home/PiP hides or detaches the view. Only ending the
        // call releases the restriction; read after @Published installs its value.
        registration.observation = player.$callPhase.sink { [weak self, weak registration] _ in
            Task { @MainActor [weak self, weak registration] in
                guard let self, let registration else { return }
                self.scheduleRefresh(registration, force: false)
            }
        }
        scheduleRefresh(registration, force: true)
    }

    private func refreshActiveScenes() {
        for key in Array(registrations.keys) {
            guard let registration = registrations[key] else { continue }
            guard registration.scene != nil else { registrations.removeValue(forKey: key); continue }
            scheduleRefresh(registration, force: true)
        }
    }

    private func scheduleRefresh(_ registration: Registration, force: Bool) {
        let mask: UIInterfaceOrientationMask = registration.player?.isInCall == true ? .portrait : .allButUpsideDown
        guard force || registration.lastRequestedMask != mask else { return }
        registration.forceRefresh = registration.forceRefresh || force
        guard !registration.refreshScheduled else { return }
        registration.refreshScheduled = true
        Task { @MainActor [weak self, weak registration] in
            guard let self, let registration else { return }
            registration.refreshScheduled = false
            let force = registration.forceRefresh
            registration.forceRefresh = false
            self.apply(registration, force: force)
        }
    }

    private func apply(_ registration: Registration, force: Bool) {
        guard let scene = registration.scene,
              registrations[ObjectIdentifier(scene)] === registration,
              let window = registration.window,
              window.traitCollection.userInterfaceIdiom == .phone else { return }
        let mask: UIInterfaceOrientationMask = registration.player?.isInCall == true ? .portrait : .allButUpsideDown
        // Retain the policy while backgrounded; request geometry only after the
        // scene is active again. No scenePhase transition clears the call lock.
        guard scene.activationState == .foregroundActive,
              force || registration.lastRequestedMask != mask else { return }
        // Opening or returning to an ordinary player has no orientation request.
        // Restore the default range only if this registration previously requested a call lock.
        guard mask == .portrait || registration.lastRequestedMask == .portrait else {
            registration.lastRequestedMask = mask
            return
        }
        registration.lastRequestedMask = mask
        var controller = window.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            DebugLog.write("[CallOrientation] geometry request: \(error.localizedDescription)")
        }
    }
}

/// Observe the existing hosting window without replacing the player or its view hierarchy.
struct CallOrientationWindowBridge: UIViewControllerRepresentable {
    let player: PlayerController

    func makeUIViewController(context: Context) -> CallOrientationWindowObserver {
        let controller = CallOrientationWindowObserver()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: CallOrientationWindowObserver, context: Context) {
        controller.player = player
        controller.reportWindow(forceRefresh: false)
    }

    static func dismantleUIViewController(_ controller: CallOrientationWindowObserver, coordinator: ()) {
        // The scene registration still observes callPhase, including an eventual
        // hangup from PiP or another screen. Disappearance alone must not unlock it.
        controller.player = nil
    }
}

@MainActor
final class CallOrientationWindowObserver: UIViewController {
    weak var player: PlayerController?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reportWindow(forceRefresh: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportWindow(forceRefresh: false)
    }

    func reportWindow(forceRefresh: Bool) {
        // The initial SwiftUI update may precede window attachment. Layout and
        // appearance supply the real window later, without polling or a global scene guess.
        guard let player, let window = viewIfLoaded?.window else { return }
        CallOrientationPolicy.shared.attach(player: player, window: window, forceRefresh: forceRefresh)
    }
}
