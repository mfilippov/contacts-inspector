import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Нужно, только если бинарник запущен не из .app (например, swift run)
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        if UserDefaults.standard.bool(forKey: "debugSnapshots") { installEventLogging() }
        if ProcessInfo.processInfo.environment["CC_SNAPSHOTS"] != nil
            || UserDefaults.standard.bool(forKey: "debugSnapshots") { startSnapshots() }
    }
    /// Отладка: раз в 2 с сохраняем снимок своего окна в ~/Library/Logs/ContactsInspector-snap.png
    /// (рисуем собственный view — разрешение на запись экрана не требуется).
    private var snapTimer: Timer?
    func startSnapshots() {
        snapTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let view = win.contentView?.superview ?? win.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/ContactsInspector-snap.png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }

    private var monitor: Any?
    func installEventLogging() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in debugLog("event: \(n.name.rawValue)") }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            debugLog("mouse \(e.type == .leftMouseDown ? "down" : "up") at \(e.locationInWindow) keyWin=\(e.window?.isKeyWindow ?? false) active=\(NSApp.isActive)")
            return e
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ContactsInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Contacts Inspector") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 600)
                .task { if model.state == .idle { await model.load() } }
        }
        .defaultSize(width: 1500, height: 900)
    }
}
