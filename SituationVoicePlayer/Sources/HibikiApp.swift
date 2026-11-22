import SwiftUI

@main
struct HibikiApp: App {
    @UIApplicationDelegateAdaptor(CallOrientationAppDelegate.self) private var orientationDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            // 调试用启动参数：方便在没有 UI 自动化时单独验证某个页面
            //   -coreCheck   直接打开内核自检
            //   -statistics  直接切到统计页
            if CommandLine.arguments.contains("-coreCheck") {
                NavigationStack { CoreCheckView() }
            } else if CommandLine.arguments.contains("-statistics") {
                RootView(initialTab: .statistics)
            } else if CommandLine.arguments.contains("-settings") {
                RootView(initialTab: .settings)
            } else {
                RootView()
            }
            #else
            RootView()
            #endif
            }
            .environment(\.locale, AppLanguageSelection.shared.locale)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { AppLanguageSelection.shared.refreshSystemLanguage() }
            }
        }
    }
}
