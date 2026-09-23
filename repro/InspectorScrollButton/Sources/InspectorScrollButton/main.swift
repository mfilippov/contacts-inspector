// Repro: on macOS 27.0 (26A428) a Button inside a ScrollView that is the root of `.inspector`
// content does not receive clicks. The same button inside Form(.grouped) or List works.
//
// Usage: build, wrap into an .app (see README), run:  open -n Repro.app --args <log path> <scroll|form>
// The app clicks every SwiftUI button with a synthetic mouse event and logs which actions fired.
import AppKit
import SwiftUI

let logURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/repro.log")
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "scroll"

func log(_ s: String) {
    let line = s + "\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

struct ContentView: View {
    @State private var showInspector = true
    var body: some View {
        NavigationSplitView {
            List { Text("Sidebar") }
        } detail: {
            Button("detail") { log("ACTION detail") }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .inspector(isPresented: $showInspector) {
                    if mode == "form" {
                        Form { Button("inspector") { log("ACTION inspector") } }.formStyle(.grouped)
                    } else {
                        ScrollView { Button("inspector") { log("ACTION inspector") } }   // ← does not receive clicks
                    }
                }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: ContentView())
        w.makeKeyAndOrderFront(nil)
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.clickAll(w) }
    }

    func clickAll(_ win: NSWindow) {
        guard let root = win.contentView?.superview else { return }
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), mode=\(mode)")
        var buttons: [NSView] = []
        func walk(_ v: NSView) {
            if String(describing: type(of: v)) == "SwiftUIAppKitButton" { buttons.append(v) }
            v.subviews.forEach(walk)
        }
        walk(root)
        var queue = buttons
        func next() {
            guard !queue.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { log("done"); exit(0) }
                return
            }
            let b = queue.removeFirst()
            let f = b.convert(b.bounds, to: nil)
            let p = NSPoint(x: f.midX, y: f.midY)
            let hit = root.hitTest(root.convert(p, from: nil)).map { String(describing: type(of: $0)) } ?? "nil"
            log("CLICK at \(Int(p.x)),\(Int(p.y)) hitTest=\(hit)")
            let t = ProcessInfo.processInfo.systemUptime
            NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: t + 0.05,
                                               windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1)!, atStart: false)
            NSApp.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: t,
                                               windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                               clickCount: 1, pressure: 1)!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
        }
        next()
    }
}

let delegate = Delegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
