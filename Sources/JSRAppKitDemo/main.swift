import AppKit
import JSRCore
import JSRAppKit

// JSRAppKitDemo (issue #3): menu mode loads the seeded fixtures into a window;
// headless mode `--conformance <fixtures> --out <dir>` runs the conformance
// runner with the AppKit driver + live-view dump and prints the report.

let seeds = ["hello", "counter", "scroll_list"]

func defaultFixturesDir() -> String {
    ProcessInfo.processInfo.environment["JSR_FIXTURES"] ?? ".conformance/js_widget_runtime/docs/conformance/fixtures"
}

/// Menu target that loads a fixture into the shared host.
final class MenuCoordinator: NSObject {
    let loader: (String) -> Void

    init(loader: @escaping (String) -> Void) {
        self.loader = loader
    }

    @objc func load(_ sender: NSMenuItem) {
        guard let seed = sender.representedObject as? String else { return }
        loader(seed)
    }
}

func runDemoWindow() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered, defer: false)
    window.title = "JSR AppKit Demo"

    let engine = JsContextEngine()
    let runtime = JsWidgetRuntime(engine: engine)
    let driver = ManualTimerDriver()
    weak var registryRef: ChannelRegistry?
    let timers = Timers(driver: driver, evaluate: { script in
        try? engine.eval(script, sourceName: "<timer>")
        registryRef?.drain()
    })
    let registry = ChannelRegistry(services: HostServices(), timers: timers, configuration: JSRConfiguration()) { script in
        try? engine.eval(script, sourceName: "<resolve>")
    }
    registryRef = registry
    let mapper = AppKitMapper(container: window.contentView!)
    mapper.onEvent = { actionId, payloadJson in
        try? runtime.callEvent(actionId, payloadJson: payloadJson)
    }

    func loadFixture(_ name: String) {
        let fixtureDir = defaultFixturesDir() + "/" + name
        guard let widget = try? String(contentsOfFile: fixtureDir + "/widget.js", encoding: .utf8) else { return }
        do {
            try runtime.start(sink: { channel, payload in
                registry.dispatch(channel: channel, payload: payload)
                if channel == "__jsr_render" {
                    try? mapper.render(payloadJSON: payload)
                }
            }, iid: "macos")
            try engine.eval(widget, sourceName: "widget.js")
            registry.drain()
            window.title = "JSR AppKit Demo — \(name)"
        } catch {
            window.title = "JSR AppKit Demo — error: \(error)"
        }
    }

    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "Quit JSRAppKitDemo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu

    let fixturesItem = NSMenuItem()
    mainMenu.addItem(fixturesItem)
    let fixturesMenu = NSMenu(title: "Fixtures")
    fixturesItem.submenu = fixturesMenu
    let coordinator = MenuCoordinator(loader: loadFixture)
    for seed in seeds {
        let item = NSMenuItem(title: "Load \(seed)", action: #selector(MenuCoordinator.load(_:)), keyEquivalent: "")
        item.target = coordinator
        item.representedObject = seed
        fixturesMenu.addItem(item)
    }
    app.mainMenu = mainMenu

    window.center()
    loadFixture(seeds[0])
    app.activate(ignoringOtherApps: true)
    app.run()
}

func conformanceHeadless(fixtures: String, out: String) {
    _ = NSApplication.shared // AppKit classes need the app object, not the event loop
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    var lines: [String] = ["| Fixture | Level | Status | Diffs |"]
    var done = 0
    for seed in seeds {
        let runner = ConformanceRunner(fixturesDir: fixtures, outDir: out)
        runner.iid = "macos"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        var mapper: AppKitMapper?
        runner.renderObserver = { payload in
            try? mapper?.render(payloadJSON: payload)
        }
        runner.customFinalDump = { interaction in
            (interaction as? AppKitInteractionDriver)?.mapper.dump()
        }
        let result = try? runner.run(fixture: seed, driverFactory: { runtime, recorder, registry, engine in
            let appKitMapper = AppKitMapper(container: container)
            appKitMapper.onEvent = { actionId, payloadJson in
                try? runtime.callEvent(actionId, payloadJson: payloadJson)
            }
            mapper = appKitMapper
            return AppKitInteractionDriver(mapper: appKitMapper, runtime: runtime, registry: registry, engine: engine)
        })
        let status = (result?["status"] as? String) ?? "DONE"
        done += 1
        lines.append("| \(seed) | seed | \(status) | - |")
        if let error = result?["error"] as? String {
            lines.append("  error: \(error)")
        }
    }
    lines.append("Ran \(done) seeds on macOS; verdicts come from jsr-harness compare.")
    let report = lines.joined(separator: "\n")
    print(report)
    try? report.write(toFile: out + "/report.md", atomically: true, encoding: .utf8)
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--conformance"), index + 1 < arguments.count {
    let fixtures = arguments[index + 1]
    let out = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "/tmp/apple-macos"
    conformanceHeadless(fixtures: fixtures, out: out)
} else {
    runDemoWindow()
}
