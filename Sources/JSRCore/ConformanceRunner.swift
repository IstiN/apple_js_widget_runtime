import Foundation

// Conformance runner (plan 1.4): reads meta.json/expected.json of a fixture,
// boots the widget through the real bootstrap halves on the host engine,
// performs the actions through an InteractionDriver, writes result.json.
// The host run (JSContext, no views) uses TreeInteractionDriver; the AppKit and
// UIKit demos plug view-backed drivers (P2/P3) into the same runner.

public protocol InteractionDriver: AnyObject {
    /// `target` is a nodeId ("n2") or visible text; returns false when not found.
    func tap(target: String) -> Bool
    func input(node: String, value: String) -> Bool
    /// Keyboard done on the text node: dispatches `onSubmit` ?? `onSubmitted`
    /// (PROTOCOL v0.2 amendment A1) with `{"value": <current text>}`.
    func submit(node: String) -> Bool
    func scroll(dx: Double, dy: Double)
    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Double)
    /// Real time on every platform.
    func wait(ms: Double)
    /// Host event `back` through the reference global `__jsrHostEvent`.
    func back()
}

/// Settled content move of a touch flick (PROTOCOL A2/A3): the gesture delta
/// plus the momentum coast of a finger moving `delta` px over `ms` — velocity
/// v = delta/ms, normal deceleration 0.998 per ms coasts v*r/(1-r) beyond the
/// gesture (the UIScrollView numbers). The AppKit and UIKit drivers apply
/// their scroll through this, so the dumped `scrollOffset` reflects the real
/// touch gesture, not just its raw travel.
public func flickCarry(_ delta: Double, ms: Double) -> Double {
    guard ms > 0 else { return delta }
    let velocity = delta / ms // px per ms
    let rate = 0.998
    return delta + velocity * rate / (1 - rate)
}

/// Tree-level driver for the host conformance loop: finds the node in the
/// current tree and dispatches the event — no views involved.
public final class TreeInteractionDriver: InteractionDriver {
    private let runtime: JsWidgetRuntime
    private let recorder: HostRecorder
    private let registry: ChannelRegistry
    private let engine: JsEngine

    public init(runtime: JsWidgetRuntime, recorder: HostRecorder, registry: ChannelRegistry, engine: JsEngine) {
        self.runtime = runtime
        self.recorder = recorder
        self.registry = registry
        self.engine = engine
    }

    /// The normalized tree of the last applied render.
    public func currentTree() -> WidgetNode? {
        guard let payload = recorder.renders.last else { return nil }
        return try? AuiDump.normalizeTree(payloadJSON: payload)
    }

    public func tap(target: String) -> Bool {
        guard let node = findNode(target: target, tree: currentTree()),
              let action = node.events["onTap"] ?? node.events["onClick"] ?? node.events["onPressed"] else { return false }
        try? runtime.callEvent(action, payloadJson: "{}")
        registry.drain()
        return true
    }

    public func input(node target: String, value: String) -> Bool {
        guard let node = findNode(target: target, tree: currentTree()),
              let action = node.events["onChanged"] ?? node.events["onChange"] else { return false }
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": value]))
        registry.drain()
        return true
    }

    public func submit(node target: String) -> Bool {
        guard let node = findNode(target: target, tree: currentTree()),
              let action = node.events["onSubmit"] ?? node.events["onSubmitted"] else { return false }
        let value = node.textContent ?? ""
        try? runtime.callEvent(action, payloadJson: JSON.stringify(["value": value]))
        registry.drain()
        return true
    }

    public func scroll(dx: Double, dy: Double) {
        // The tree-level driver has no scroll container; view drivers (P2/P3)
        // synthesize the scroll events on the mapped view.
    }

    public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Double) {}

    public func wait(ms: Double) {
        Thread.sleep(forTimeInterval: ms / 1000.0)
        registry.drain()
    }

    public func back() {
        try? engine.eval("__jsrHostEvent(\"back\", {})", sourceName: "<host-event>")
        registry.drain()
    }

    /// `nodeId` when target matches /^n\d+$/, else the first node whose
    /// text-bearing prop equals the target.
    func findNode(target: String, tree: WidgetNode?) -> WidgetNode? {
        guard let tree else { return nil }
        if target.range(of: "^n\\d+$", options: .regularExpression) != nil {
            return tree.first(where: { $0.nodeId == target })
        }
        return tree.first(where: { $0.textContent == target })
    }
}

public enum ConformanceRunnerError: Error {
    case fixtureNotFound(String)
}

public final class ConformanceRunner {
    public static let supportedCapabilities: Set<String> = ["network", "storage", "secrets", "assets"]

    private let fixturesDir: String
    private let outDir: String
    /// Instance id of the host run; lands in dumps via the routing tag.
    public var iid = "apple-host"
    /// View-backed drivers can produce the FINAL dump from live views
    /// (text-bearing props read from the view, plan 1.3). nil → record-derived.
    public var customFinalDump: ((_ interaction: InteractionDriver) -> [String: Any]?)?
    /// View-backed drivers can produce the INITIAL dump from live views too —
    /// A3 scroll state must be present on every dump, and the record-derived
    /// initial dump carries no scroll state. The provider returns the snapshot
    /// captured at the first render; nil → record-derived.
    public var customInitialDump: (() -> [String: Any]?)?
    /// Observes every `__jsr_render` payload (view mappers re-render from it).
    public var renderObserver: ((_ payloadJSON: String) -> Void)?

    public init(fixturesDir: String, outDir: String) {
        self.fixturesDir = fixturesDir
        self.outDir = outDir
    }

    /// Loads the fixture files; nil-throwing wrapper for the widget/meta read.
    struct FixtureFiles {
        let widget: String
        let meta: [String: Any]
        let expected: [String: Any]
        let dir: String
    }

    static func loadFixture(fixturesDir: String, id: String) throws -> FixtureFiles {
        let dir = fixturesDir + "/" + id
        guard let widget = try? String(contentsOfFile: dir + "/widget.js", encoding: .utf8),
              let metaData = try? Data(contentsOf: URL(fileURLWithPath: dir + "/meta.json")),
              let meta = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
            throw ConformanceRunnerError.fixtureNotFound(id)
        }
        let expected = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/expected.json")))) as? [String: Any] ?? [:]
        return FixtureFiles(widget: widget, meta: meta, expected: expected, dir: dir)
    }

    /// First capability the host does not support, if any (plan 1.4).
    static func unsupportedCapability(in meta: [String: Any]) -> String? {
        let capabilities = meta["capabilities"] as? [String] ?? []
        return capabilities.first { !supportedCapabilities.contains($0) }
    }

    /// The full engine+registry boot of the conformance loop.
    struct Booted {
        let engine: JsContextEngine
        let runtime: JsWidgetRuntime
        let registry: ChannelRegistry
        let timers: ManualTimerDriver
        let recorder: HostRecorder
    }

    static func boot(files: FixtureFiles) -> Booted {
        let driverImpl = ManualTimerDriver()
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        weak var registryRef: ChannelRegistry?
        let timers = Timers(driver: driverImpl, evaluate: { script in
            try? engine.eval(script, sourceName: "<timer>")
            registryRef?.drain()
        })
        let services = HostServices(
            http: MockHttp(mock: files.meta["mock"] as? [String: Any] ?? [:]),
            assets: FileAssetLoader(rootPath: files.dir))
        let registry = ChannelRegistry(services: services, timers: timers, configuration: JSRConfiguration()) { script in
            try? engine.eval(script, sourceName: "<resolve>")
        }
        registryRef = registry
        return Booted(engine: engine, runtime: runtime, registry: registry,
                      timers: driverImpl, recorder: registry.recorder)
    }

    /// Runs one fixture; returns the result dict it wrote (or would write).
    @discardableResult
    public func run(fixture id: String, driverFactory: (JsWidgetRuntime, HostRecorder, ChannelRegistry, JsEngine) -> InteractionDriver = { runtime, recorder, registry, engine in
        TreeInteractionDriver(runtime: runtime, recorder: recorder, registry: registry, engine: engine)
    }) throws -> [String: Any] {
        let files = try ConformanceRunner.loadFixture(fixturesDir: fixturesDir, id: id)
        if let unsupported = ConformanceRunner.unsupportedCapability(in: files.meta) {
            return finish(id: id, status: "SKIP", skippedReason: "unsupported capability: \(unsupported)",
                          recorder: HostRecorder(), fixtureDir: files.dir)
        }
        let booted = ConformanceRunner.boot(files: files)
        // the view driver mounts BEFORE the widget evaluates so its mapper
        // observes the initial render through renderObserver
        let interaction = driverFactory(booted.runtime, booted.recorder, booted.registry, booted.engine)

        do {
            try booted.runtime.start(sink: { [weak self] channel, payload in
                booted.registry.dispatch(channel: channel, payload: payload)
                if channel == "__jsr_render" {
                    self?.renderObserver?(payload)
                }
            }, iid: iid)
            // PROTOCOL §3.4: the mock-origin global exists before the widget
            // runs; the Apple host resolves mocks by path (MockHttp.lookup),
            // so a sentinel origin is enough (review 2026-11-26, finding 2).
            try booted.engine.eval("var __JSR_MOCK_ORIGIN__ = \"http://jsr.local\";", sourceName: "<mock-origin>")
            try booted.engine.eval(files.widget, sourceName: "widget.js")
            booted.registry.drain()

            let actions = files.expected["actions"] as? [[String: Any]] ?? []
            for action in actions {
                apply(action, to: interaction)
            }
        } catch {
            return finish(id: id, status: "DONE", error: "\(error)", recorder: booted.recorder,
                          fixtureDir: files.dir, viewDriver: interaction)
        }
        return finish(id: id, status: "DONE", recorder: booted.recorder,
                      fixtureDir: files.dir, viewDriver: interaction)
    }

    /// Runs every fixture directory under `fixturesDir`.
    @discardableResult
    public func runAll(filter: String? = nil) throws -> [String] {
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let ids = try FileManager.default.contentsOfDirectory(atPath: fixturesDir).sorted()
        var statuses: [String] = []
        for id in ids {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fixturesDir + "/" + id, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let filter, !globMatch(filter, id) { continue }
            let result = try run(fixture: id)
            statuses.append(result["status"] as? String ?? "DONE")
        }
        return statuses
    }

    // MARK: - plumbing

    private func apply(_ action: [String: Any], to driver: InteractionDriver) {
        if applyTap(action, to: driver) { return }
        if applyInput(action, to: driver) { return }
        if applySubmit(action, to: driver) { return }
        if applyScroll(action, to: driver) { return }
        if applySwipe(action, to: driver) { return }
        if applyWait(action, to: driver) { return }
        applyBack(action, to: driver)
    }

    private func applyTap(_ action: [String: Any], to driver: InteractionDriver) -> Bool {
        guard let tap = action["tap"] as? String else { return false }
        _ = driver.tap(target: tap)
        return true
    }

    private func applyInput(_ action: [String: Any], to driver: InteractionDriver) -> Bool {
        guard let input = action["input"] as? [String: Any] else { return false }
        _ = driver.input(node: input["node"] as? String ?? "", value: input["value"] as? String ?? "")
        return true
    }

    private func applySubmit(_ action: [String: Any], to driver: InteractionDriver) -> Bool {
        guard let submit = action["submit"] as? String else { return false }
        _ = driver.submit(node: submit)
        return true
    }

    private func applyScroll(_ action: [String: Any], to driver: InteractionDriver) -> Bool {
        guard let scroll = action["scroll"] as? [Any], scroll.count == 2 else { return false }
        let numbers = scroll.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        driver.scroll(dx: numbers[0], dy: numbers[1])
        return true
    }

    private func applySwipe(_ action: [String: Any], to driver: InteractionDriver) -> Bool {
        guard let swipe = action["swipe"] as? [Any], swipe.count == 5 else { return false }
        let numbers = swipe.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        driver.swipe(x1: numbers[0], y1: numbers[1], x2: numbers[2], y2: numbers[3], ms: numbers[4])
        return true
    }

    private func applyWait(_ action: [String: Any], to driver: InteractionDriver) -> Bool {
        guard let waitMs = (action["wait"] as? NSNumber)?.doubleValue else { return false }
        driver.wait(ms: waitMs)
        return true
    }

    private func applyBack(_ action: [String: Any], to driver: InteractionDriver) {
        if let back = action["back"] as? Bool, back {
            driver.back()
        }
    }

    /// result.json per plan 1.4: PASS is set by the harness; the runner writes DONE/SKIP.
    private func finish(id: String, status: String, error: String? = nil, skippedReason: String? = nil, recorder: HostRecorder, fixtureDir: String, viewDriver: InteractionDriver? = nil) -> [String: Any] {
        let dump = customInitialDump?() ?? ConformanceRunner.initialDump(of: recorder)
        let finalDump = ConformanceRunner.finalDump(of: recorder, viewDriver: viewDriver, custom: customFinalDump)
#if os(iOS)
        let platformName = "ios"
#else
        let platformName = "macos"
#endif
        let result: [String: Any] = [
            "fixture": id,
            "platform": platformName,
            "status": status,
            "dump": dump,
            "trace": recorder.trace,
            "diffs": [Any](),
            "screenshot": NSNull(),
            "renders": recorder.renders,
            "finalDump": finalDump,
            "title": recorder.title ?? NSNull(),
            "state": recorder.state ?? NSNull(),
            "console": recorder.consoleLines,
            "error": error ?? NSNull(),
            "skippedReason": skippedReason ?? NSNull(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: outDir + "/" + id + ".result.json"))
        }
        return result
    }

    /// The FIRST render, normalized (initial dump).
    private static func initialDump(of recorder: HostRecorder) -> Any {
        guard let first = recorder.renders.first, let tree = try? AuiDump.normalizeTree(payloadJSON: first) else {
            return NSNull()
        }
        return tree.jsonObject
    }

    /// Live view dump when a driver provides one, else the LAST render normalized.
    private static func finalDump(of recorder: HostRecorder, viewDriver: InteractionDriver?, custom: ((_ interaction: InteractionDriver) -> [String: Any]?)?) -> Any {
        if let custom, let viewDriver, let live = custom(viewDriver) {
            return live // view-backed dump: text-bearing props read live from the view
        }
        guard let last = recorder.renders.last, let tree = try? AuiDump.normalizeTree(payloadJSON: last) else {
            return NSNull()
        }
        return tree.jsonObject
    }

    /// `--filter <glob>`: `*` wildcards, otherwise exact id match.
    private func globMatch(_ pattern: String, _ id: String) -> Bool {
        guard pattern.contains("*") else { return pattern == id }
        let regex = "^" + pattern.map { character -> String in
            character == "*" ? ".*" : NSRegularExpression.escapedPattern(for: String(character))
        }.joined() + "$"
        return id.range(of: regex, options: .regularExpression) != nil
    }
}
