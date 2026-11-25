#if canImport(UIKit) && os(iOS)
import UIKit
import JSRCore
import JSRUIKit

// One demo host: boots engine+registry+mapper+driver and loads a fixture into
// the window. Library code so Tests/JSRUIKitTests exercise the exact demo path
// in the application window (conformance on iOS, platform "ios").

public let jsrUIKitDemoSeeds = ["hello", "counter", "scroll_list"]

public final class JSRUIKitDemoHost {
    public private(set) var windowTitle = "JSR UIKit Demo"
    public let engine: JsContextEngine
    public let runtime: JsWidgetRuntime
    public let timers: ManualTimerDriver
    public let registry: ChannelRegistry
    public let mapper: UIKitMapper

    public init(container: UIView) {
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
        let mapper = UIKitMapper(container: container)
        mapper.onEvent = { [weak runtime] actionId, payloadJson in
            try? runtime?.callEvent(actionId, payloadJson: payloadJson)
        }
        self.engine = engine
        self.runtime = runtime
        self.timers = timers
        self.registry = registry
        self.mapper = mapper
    }

    /// Evaluates the widget through the host chain and renders it live.
    public func load(widget: String, name: String) {
        do {
            try runtime.start(sink: { [registry, mapper] channel, payload in
                registry.dispatch(channel: channel, payload: payload)
                if channel == "__jsr_render" {
                    try? mapper.render(payloadJSON: payload)
                }
            }, iid: "ios")
            try engine.eval(widget, sourceName: "widget.js")
            registry.drain()
            windowTitle = "JSR UIKit Demo — \(name)"
        } catch {
            windowTitle = "JSR UIKit Demo — error: \(error)"
        }
    }
}

/// Headless-style conformance over the seeds with real UIKit views: writes
/// result.json per fixture (platform "ios") for the harness compare.
public enum jsrUIKitConformance {
    /// Mirrors the AppKit headless loop with the live-view dump.
    @MainActor
    public static func run(fixtures: String, out: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: out, withIntermediateDirectories: true)
        var lines: [String] = ["| Fixture | Level | Status | Diffs |"]
        var done = 0
        for seed in jsrUIKitDemoSeeds {
            let runner = ConformanceRunner(fixturesDir: fixtures, outDir: out)
            runner.iid = "ios"
            let container = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
            var mapper: UIKitMapper?
            runner.renderObserver = { payload in
                try? mapper?.render(payloadJSON: payload)
            }
            runner.customFinalDump = { interaction in
                (interaction as? UIKitInteractionDriver)?.mapper.dump()
            }
            let result = try? runner.run(fixture: seed, driverFactory: { runtime, recorder, registry, engine in
                let uiKitMapper = UIKitMapper(container: container)
                uiKitMapper.onEvent = { [weak runtime] actionId, payloadJson in
                    try? runtime?.callEvent(actionId, payloadJson: payloadJson)
                }
                mapper = uiKitMapper
                return UIKitInteractionDriver(mapper: uiKitMapper, runtime: runtime, registry: registry, engine: engine)
            })
            done += 1
            let status = (result?["status"] as? String) ?? "DONE"
            lines.append("| \(seed) | seed | \(status) | - |")
            if let error = result?["error"] as? String {
                lines.append("  error: \(error)")
            }
        }
        let report = "Ran \(done) seeds on iOS (simulator).\n" + lines.joined(separator: "\n")
        print(report)
        try? report.write(toFile: out + "/report.md", atomically: true, encoding: .utf8)
    }
}
#endif
