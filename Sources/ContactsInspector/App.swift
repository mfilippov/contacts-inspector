import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var telegram: TelegramService?

    /// TDLib нельзя оставлять работающей при exit(): её глобальные объекты C++ разрушаются,
    /// пока поток TDLibKit ещё вызывает td_json_receive, → SIGSEGV. Поэтому закрываем TDLib штатно
    /// и завершаемся через _exit, минуя деструкторы C++.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let tg = telegram, tg.tdlibStarted else { return .terminateNow }
        Task { @MainActor in
            await tg.shutdown()
            UserDefaults.standard.synchronize()
            _exit(0)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Нужно, только если бинарник запущен не из .app (например, swift run)
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        AppAppearance.current.apply()
        #if DEBUG
        DebugTools.shared.installIfEnabled()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ContactsInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var telegram = TelegramService()

    var body: some Scene {
        // одно окно: второе делило бы с первым выделение и инспектор
        Window("Contacts Inspector", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(telegram)
                .frame(minWidth: 1000, minHeight: 600)
                .task {
                    model.telegram = telegram
                    #if DEBUG
                    DebugTools.shared.model = model
                    #endif
                    delegate.telegram = telegram
                    if model.state == .idle { await model.load() }
                    if telegram.hasSession { telegram.start() }
                }
        }
        .defaultSize(width: 1500, height: 900)

        Settings {
            SettingsView()
        }
    }
}
