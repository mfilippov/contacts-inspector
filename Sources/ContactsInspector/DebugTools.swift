import AppKit

/// Отладочные инструменты (включаются через defaults, в обычной работе выключены):
///   debugSnapshots — раз в 2 с снимок окна в ~/Library/Logs/ContactsInspector-snap.png
///   debugTools     — лог активации окна и кликов (с hit-test view) + команды из файла
///                    ~/Library/Logs/ContactsInspector-cmd.txt:
///                      snap            — снимок окна сейчас
///                      click X Y       — синтетический клик, точки от левого верхнего угла окна
///                      views X Y       — цепочка view под точкой
@MainActor
final class DebugTools {
    static let shared = DebugTools()
    weak var model: AppModel?
    private var timers: [Timer] = []
    private var monitor: Any?
    private let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")

    func installIfEnabled() {
        let d = UserDefaults.standard
        if d.bool(forKey: "debugSnapshots") {
            timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { DebugTools.shared.snapshot() }
            })
        }
        if d.bool(forKey: "debugTools") {
            installEventLogging()
            timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { DebugTools.shared.pollCommands() }
            })
        }
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
    }

    func snapshot() {
        guard let win = window, let view = win.contentView?.superview ?? win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: logs.appendingPathComponent("ContactsInspector-snap.png"))
    }

    private func installEventLogging() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in debugLog("event: \(n.name.rawValue)") }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
            let hit = e.window.flatMap { DebugTools.viewChain(in: $0, at: e.locationInWindow, depth: 4) } ?? "?"
            debugLog("mouse \(e.type == .leftMouseDown ? "down" : "up") at \(e.locationInWindow) keyWin=\(e.window?.isKeyWindow ?? false) hit=\(hit)")
            return e
        }
    }

    /// Классы view под точкой (снизу вверх по иерархии).
    static func viewChain(in win: NSWindow, at p: NSPoint, depth: Int) -> String {
        guard let root = win.contentView?.superview else { return "-" }
        var v = root.hitTest(root.convert(p, from: nil))
        var names: [String] = []
        while let cur = v, names.count < depth {
            names.append(String(describing: type(of: cur)).prefix(40).description)
            v = cur.superview
        }
        return names.joined(separator: " < ")
    }

    private func pollCommands() {
        let url = logs.appendingPathComponent("ContactsInspector-cmd.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").map(String.init)
            guard let cmd = parts.first, let win = window else { continue }
            let h = win.frame.height
            func point() -> NSPoint? {
                guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) else { return nil }
                return NSPoint(x: x, y: h - y)
            }
            switch cmd {
            case "snap":
                snapshot()
                debugLog("cmd snap")
            case "views":
                if let p = point() { debugLog("cmd views \(p): \(DebugTools.viewChain(in: win, at: p, depth: 12))") }
            case "tree":
                // все NSControl внутри ближайшего HostingScrollView под точкой, с рамками (от верха окна)
                guard let p = point(), let root = win.contentView?.superview,
                      var v = root.hitTest(root.convert(p, from: nil)) else { continue }
                while let sup = v.superview, !String(describing: type(of: v)).contains("HostingScrollView") { v = sup }
                var out: [String] = []
                func walk(_ x: NSView, _ depth: Int) {
                    let f = x.convert(x.bounds, to: nil)
                    let name = String(describing: type(of: x))
                    if x is NSControl || depth <= 3 {
                        let title = (x as? NSButton)?.title ?? ""
                        out.append("\(String(repeating: " ", count: depth))\(name.prefix(50)) '\(title)' x=\(Int(f.minX)) y=\(Int(h - f.maxY)) w=\(Int(f.width)) h=\(Int(f.height))\(x.isHidden ? " hidden" : "")\(x.alphaValue < 1 ? " alpha=\(x.alphaValue)" : "")")
                    }
                    for c in x.subviews { walk(c, depth + 1) }
                }
                walk(v, 0)
                debugLog("cmd tree (\(out.count)):\n" + out.joined(separator: "\n"))
            case "select":
                // select 0,1 — выделить строки таблицы контактов по номерам в текущем порядке
                guard let model, parts.count >= 2 else { continue }
                let idx = parts[1].split(separator: ",").compactMap { Int($0) }
                model.tableSelection = Set(idx.compactMap { model.tableOrder.indices.contains($0) ? model.tableOrder[$0] : nil })
                debugLog("cmd select \(idx) -> \(model.tableSelection.count)")
            case "merge":
                guard let model else { continue }
                model.mergeIds = Array(model.tableSelection)
                debugLog("cmd merge \(model.tableSelection.count)")
            case "filter":
                guard let model, parts.count >= 2 else { continue }
                model.filter = parts[1] == "duplicates" ? .duplicates : .all
                debugLog("cmd filter \(parts[1])")
            case "click":
                guard let p = point() else { continue }
                debugLog("cmd click \(p)")
                click(win, at: p)
            default:
                debugLog("cmd unknown: \(line)")
            }
        }
    }

    private func click(_ win: NSWindow, at p: NSPoint) {
        let t = ProcessInfo.processInfo.systemUptime
        func ev(_ type: NSEvent.EventType, _ dt: Double) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t + dt,
                               windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = ev(.leftMouseDown, 0), let up = ev(.leftMouseUp, 0.05) else { return }
        NSApp.postEvent(up, atStart: false)   // для цикла отслеживания кнопки после mouseDown
        NSApp.sendEvent(down)
    }
}
