import AppKit
import JSRAppKit

// macOS demo shell (P2 adds the fixture picker and `--conformance <fixtures> --out <dir>`).
let app = NSApplication.shared
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered, defer: false)
window.title = "JSR AppKit Demo"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
