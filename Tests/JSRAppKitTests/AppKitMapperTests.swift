import AppKit
import Testing
import Foundation
import JSRCore
@testable import JSRAppKit

// AppKit mapping tests without a window (views laid out by hand; the
// window-backed interaction runs in the P3 CI `macos` job via the demo).

private func fixturesRoot() -> String {
    let file = URL(fileURLWithPath: #filePath)
    let packageRoot = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    return packageRoot + "/.conformance/js_widget_runtime/docs/conformance/fixtures"
}

/// Mapper bound to a runtime whose sink dispatches to the registry and
/// re-renders the mapper — the exact demo wiring, no NSApplication needed.
private struct AppKitTestHost {
    let mapper: AppKitMapper
    let runtime: JsWidgetRuntime
    let registry: ChannelRegistry
    let engine: JsContextEngine
    let timers: ManualTimerDriver

    static func make(seed: String? = nil) throws -> AppKitTestHost {
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        let timers = ManualTimerDriver()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        let mapper = AppKitMapper(container: container)
        weak var registryRef: ChannelRegistry?
        let hostTimers = Timers(driver: timers, evaluate: { script in
            try? engine.eval(script, sourceName: "<timer>")
            registryRef?.drain()
        })
        let registry = ChannelRegistry(services: HostServices(), timers: hostTimers, configuration: JSRConfiguration()) { script in
            try? engine.eval(script, sourceName: "<resolve>")
        }
        registryRef = registry
        mapper.onEvent = { actionId, payloadJson in
            try? runtime.callEvent(actionId, payloadJson: payloadJson)
        }
        try runtime.start(sink: { channel, payload in
            registry.dispatch(channel: channel, payload: payload)
            if channel == "__jsr_render" {
                try? mapper.render(payloadJSON: payload)
            }
        }, iid: "macos")
        if let seed {
            let widget = try String(contentsOfFile: fixturesRoot() + "/" + seed + "/widget.js", encoding: .utf8)
            try engine.eval(widget, sourceName: "widget.js")
            registry.drain()
        }
        return AppKitTestHost(mapper: mapper, runtime: runtime, registry: registry, engine: engine, timers: timers)
    }

    /// The comparator's derived expectation: normalizeTree of the last render.
    func derivedFinalDump() throws -> [String: Any] {
        guard let payload = registry.recorder.renders.last else { return [:] }
        return try AuiDump.normalizeTree(payloadJSON: payload).jsonObject
    }
}

private func findScroll(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for subview in view.subviews {
        if let scroll = findScroll(in: subview) { return scroll }
    }
    return nil
}

@Suite @MainActor struct AppKitMapperTests {
    @Test func helloMapsToAppKitViewsWithNodeIds() throws {
        let host = try AppKitTestHost.make(seed: "hello")
        // center > column > [text, sizedBox, textButton]
        let center = host.mapper.container.subviews.first
        #expect(center?.accessibilityIdentifier() == "n0")
        let column = center?.subviews.first as? NSStackView
        #expect(column?.orientation == .vertical)
        #expect((column?.spacing ?? 0) == 12)
        let arranged = column?.arrangedSubviews ?? []
        #expect(arranged.count == 3)
        #expect((arranged[0] as? NSTextField)?.stringValue == "Hello from JS!")
        #expect(arranged[1].accessibilityIdentifier() == "n3") // sizedBox
        let button = arranged[2] as? NSButton
        #expect(button?.title == "Tap me")
        #expect(button?.accessibilityIdentifier() == "n4")
        // the center keeps the column centered (resize-safe Auto Layout)
        var centeredX = false
        var centeredY = false
        if let center, let column {
            for constraint in center.constraints where constraint.firstItem === column {
                if constraint.firstAttribute == .centerX { centeredX = true }
                if constraint.firstAttribute == .centerY { centeredY = true }
            }
        }
        #expect(centeredX)
        #expect(centeredY)
    }

    @Test func dumpOfRealViewsEqualsDerivedExpectationHello() throws {
        let host = try AppKitTestHost.make(seed: "hello")
        #expect(JSON.valuesEqual(try host.derivedFinalDump(), host.mapper.dump()))
    }

    @Test func dumpOfRealViewsEqualsDerivedExpectationCounter() throws {
        let host = try AppKitTestHost.make(seed: "counter")
        #expect(JSON.valuesEqual(try host.derivedFinalDump(), host.mapper.dump()))
    }

    @Test func scrollListContainersRenderTheirChildren() throws {
        let host = try AppKitTestHost.make(seed: "scroll_list")
        let live = host.mapper.dump()
        // 30 containers each carry their two texts (flutter #11 does not apply here)
        func countTexts(_ node: [String: Any]) -> Int {
            var total = node["type"] as? String == "text" ? 1 : 0
            for child in node["children"] as? [[String: Any]] ?? [] {
                total += countTexts(child)
            }
            return total
        }
        #expect(countTexts(live) == 60)
        #expect(JSON.valuesEqual(try host.derivedFinalDump(), live))
    }

    @Test func counterTapsPatchWithoutRebuild() throws {
        let host = try AppKitTestHost.make(seed: "counter")
        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        #expect(driver.tap(target: "+1"))
        // one counter tap is exactly one updateProps — no rebuild
        #expect(host.mapper.lastOperations.count == 1)
        guard case let .updateProps(nodeId, props)? = host.mapper.lastOperations.first else {
            Issue.record("expected updateProps, got \(host.mapper.lastOperations)")
            return
        }
        #expect(nodeId == "n3" && (props["data"] as? String) == "1")
        #expect(driver.tap(target: "+1"))
        #expect(driver.tap(target: "-1"))
        let dump = host.mapper.dump()
        let column = ((dump["children"] as? [[String: Any]])?.first)?["children"] as? [[String: Any]]
        #expect((column?[1]["props"] as? [String: Any])?["data"] as? String == "1") // live view text
        #expect(JSON.valuesEqual(try host.derivedFinalDump(), dump))
    }

    @Test func unchangedTextKeepsItsLiveTextAcrossSiblingPatch() throws {
        let host = try AppKitTestHost.make()
        try host.engine.eval(#"jsr.render({type: 'column', children: [{type: 'text', data: 'keep me'}, {type: 'text', data: 'change me'}]});"#, sourceName: "<test>")
        host.registry.drain()
        try host.engine.eval(#"jsr.render({type: 'column', children: [{type: 'text', data: 'keep me'}, {type: 'text', data: 'changed'}]});"#, sourceName: "<test>")
        host.registry.drain()
        let stack = host.mapper.container.subviews.first as? NSStackView
        let texts = stack?.arrangedSubviews.compactMap { $0 as? NSTextField } ?? []
        #expect(texts.count == 2)
        #expect(texts[0].stringValue == "keep me") // untouched by the sibling patch
        #expect(texts[1].stringValue == "changed")
    }

    @Test func scrollViewKeepsItsScrollPositionAcrossRerender() throws {
        let host = try AppKitTestHost.make()
        try host.engine.eval(#"jsr.render({type: 'scroll', children: [{type: 'column', spacing: 4, children: [...Array(60).keys()].map(function(i){ return {type: 'text', data: 'row ' + (i + 1)}; })}]});"#, sourceName: "<test>")
        host.registry.drain()
        guard let scroll = findScroll(in: host.mapper.container) else {
            Issue.record("no NSScrollView mapped")
            return
        }
        host.mapper.container.layoutSubtreeIfNeeded()
        scroll.contentView.bounds.origin = NSPoint(x: 0, y: 200)
        // identical re-render: no patch ops, the scroll offset stays
        try host.engine.eval(#"jsr.render({type: 'scroll', children: [{type: 'column', spacing: 4, children: [...Array(60).keys()].map(function(i){ return {type: 'text', data: 'row ' + (i + 1)}; })}]});"#, sourceName: "<test>")
        host.registry.drain()
        host.mapper.container.layoutSubtreeIfNeeded()
        #expect(host.mapper.lastOperations.isEmpty)
        #expect(scroll.contentView.bounds.origin.y == 200)
    }

    @Test func fallbackCardRendersTypeNameWithTag() throws {
        let host = try AppKitTestHost.make()
        try host.engine.eval(#"jsr.render({type: 'column', children: [{type: 'slider', min: 0, max: 10}]});"#, sourceName: "<test>")
        host.registry.drain()
        let stack = host.mapper.container.subviews.first as? NSStackView
        let card = stack?.arrangedSubviews.first
        #expect(card?.accessibilityIdentifier() == "n1")
        let label = card?.subviews.compactMap { $0 as? NSTextField }.first
        #expect(label?.stringValue == "slider")
    }

    @Test func driverWaitRunsRealTimeAndDrains() throws {
        let host = try AppKitTestHost.make(seed: "hello")
        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        let started = Date()
        driver.wait(ms: 30)
        #expect(Date().timeIntervalSince(started) >= 0.02)
        #expect(driver.tap(target: "Tap me"))
        #expect(host.registry.recorder.title == "Tapped: 1") // via the real button action
    }

    @Test func demoHeadlessWritesMacosResultsForHarness() throws {
        // run the runner exactly like the demo does (AppKit driver + live dump)
        let out = ProcessInfo.processInfo.environment["JSR_CONFORMANCE_OUT"] ?? "/tmp/apple-macos"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let runner = ConformanceRunner(fixturesDir: fixturesRoot(), outDir: out)
        runner.iid = "macos"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        var mapper: AppKitMapper?
        runner.renderObserver = { payload in
            try? mapper?.render(payloadJSON: payload)
        }
        runner.customFinalDump = { interaction in
            (interaction as? AppKitInteractionDriver)?.mapper.dump()
        }
        let result = try runner.run(fixture: "counter", driverFactory: { runtime, recorder, registry, engine in
            let appKitMapper = AppKitMapper(container: container)
            appKitMapper.onEvent = { actionId, payloadJson in
                try? runtime.callEvent(actionId, payloadJson: payloadJson)
            }
            mapper = appKitMapper
            return AppKitInteractionDriver(mapper: appKitMapper, runtime: runtime, registry: registry, engine: engine)
        })
        #expect(result["platform"] as? String == "macos")
        #expect((result["renders"] as? [String])?.count == 4)
        #expect(FileManager.default.fileExists(atPath: out + "/counter.result.json"))
    }
}
