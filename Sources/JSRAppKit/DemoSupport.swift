import AppKit
import JSRCore

// Demo + headless conformance entry points (issue #3). Library code so the
// test bundle exercises the exact demo path; the executable main.swift only
// parses arguments and calls in here (no functions of its own — the CRAP gate
// scans Sources/).

public enum jsrAppKitDemo {
    public static let seeds = ["hello", "counter", "scroll_list"]
    /// The headless conformance set: the seeds plus one L2 mock fixture, so
    /// the `__JSR_MOCK_ORIGIN__` path is exercised in CI (review 2026-11-26,
    /// finding 2).
    public static let conformanceFixtures = seeds + ["l2_fetch_json"]

    public enum Mode {
        case conformance(fixtures: String, out: String)
        case menu(fixtures: String)
    }

    /// `--conformance <fixtures> [--out <dir>]` → headless; otherwise menu mode.
    public static func parseArguments(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode {
        let fixturesDefault = environment["JSR_FIXTURES"] ?? ".conformance/js_widget_runtime/docs/conformance/fixtures"
        if let index = arguments.firstIndex(of: "--conformance"), index + 1 < arguments.count {
            let out = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "/tmp/apple-macos"
            return .conformance(fixtures: arguments[index + 1], out: out)
        }
        return .menu(fixtures: fixturesDefault)
    }

    /// Headless conformance: runs the seeds through ConformanceRunner with the
    /// AppKit driver and live-view dump; writes result.json per seed + report.md.
    
    public static func runConformanceHeadless(fixtures: String, out: String) {
        _ = NSApplication.shared // AppKit classes need the app object, not the event loop
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        var lines: [String] = ["| Fixture | Level | Status | Diffs |"]
        var done = 0
        for fixture in conformanceFixtures {
            let runner = ConformanceRunner(fixturesDir: fixtures, outDir: out)
            runner.iid = "macos"
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
            var mapper: AppKitMapper?
            var firstDump: [String: Any]?
            runner.renderObserver = { payload in
                try? mapper?.render(payloadJSON: payload)
                if firstDump == nil, let mapper { firstDump = mapper.dump() } // A3: initial dump carries live scroll state
            }
            runner.customInitialDump = { firstDump }
            runner.customFinalDump = { interaction in
                (interaction as? AppKitInteractionDriver)?.mapper.dump()
            }
            let result = try? runner.run(fixture: fixture, driverFactory: { runtime, recorder, registry, engine in
                let appKitMapper = AppKitMapper(container: container)
                appKitMapper.onEvent = { actionId, payloadJson in
                    try? runtime.callEvent(actionId, payloadJson: payloadJson)
                }
                mapper = appKitMapper
                return AppKitInteractionDriver(mapper: appKitMapper, runtime: runtime, registry: registry, engine: engine)
            })
            done += 1
            let status = (result?["status"] as? String) ?? "DONE"
            lines.append("| \(fixture) | \(seeds.contains(fixture) ? "seed" : "L2") | \(status) | - |")
            if let error = result?["error"] as? String {
                lines.append("  error: \(error)")
            }
        }
        lines.append("Ran \(done) fixtures on macOS; verdicts come from jsr-harness compare.")
        let report = lines.joined(separator: "\n")
        print(report)
        try? report.write(toFile: out + "/report.md", atomically: true, encoding: .utf8)
    }

    /// Menu mode: one host; the Fixtures menu loads a seed into the window.
    public static func runMenu(fixturesRoot: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "JSR AppKit Demo"

        let host = MenuHost(container: window.contentView!)
        window.center()

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
        let coordinator = MenuCoordinator(loader: { seed in
            host.load(fixturesRoot: fixturesRoot, name: seed)
            window.title = host.windowTitle
        })
        for seed in seeds {
            let item = NSMenuItem(title: "Load \(seed)", action: #selector(MenuCoordinator.load(_:)), keyEquivalent: "")
            item.target = coordinator
            item.representedObject = seed
            fixturesMenu.addItem(item)
        }
        app.mainMenu = mainMenu

        host.load(fixturesRoot: fixturesRoot, name: seeds[0])
        window.title = host.windowTitle
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

/// One menu-mode host: boots the engine+registry+mapper chain and loads a
/// fixture into the container. Library code so tests exercise the exact
/// demo path without NSApplication (the window only carries the container).
public final class MenuHost {
    public private(set) var windowTitle = "JSR AppKit Demo"
    let engine: JsContextEngine
    let runtime: JsWidgetRuntime
    let timers: ManualTimerDriver
    let registry: ChannelRegistry
    let mapper: AppKitMapper

    public init(container: NSView) {
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        let timers = ManualTimerDriver()
        weak var registryRef: ChannelRegistry?
        let hostTimers = Timers(driver: timers, evaluate: { script in
            try? engine.eval(script, sourceName: "<timer>")
            registryRef?.drain()
        })
        let registry = ChannelRegistry(services: HostServices(), timers: hostTimers, configuration: JSRConfiguration()) { script in
            try? engine.eval(script, sourceName: "<resolve>")
        }
        registryRef = registry
        let mapper = AppKitMapper(container: container)
        mapper.onEvent = { [weak runtime] actionId, payloadJson in
            try? runtime?.callEvent(actionId, payloadJson: payloadJson)
        }
        self.engine = engine
        self.runtime = runtime
        self.timers = timers
        self.registry = registry
        self.mapper = mapper
    }

    /// Evaluates `<fixturesRoot>/<name>/widget.js` through the host chain.
    public func load(fixturesRoot: String, name: String) {
        let fixtureDir = fixturesRoot + "/" + name
        guard let widget = try? String(contentsOfFile: fixtureDir + "/widget.js", encoding: .utf8) else {
            windowTitle = "JSR AppKit Demo — missing fixture: \(name)"
            return
        }
        do {
            try runtime.start(sink: { [registry, mapper] channel, payload in
                registry.dispatch(channel: channel, payload: payload)
                if channel == "__jsr_render" {
                    try? mapper.render(payloadJSON: payload)
                }
            }, iid: "macos")
            try engine.eval(widget, sourceName: "widget.js")
            registry.drain()
            windowTitle = "JSR AppKit Demo — \(name)"
        } catch {
            windowTitle = "JSR AppKit Demo — error: \(error)"
        }
    }
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
