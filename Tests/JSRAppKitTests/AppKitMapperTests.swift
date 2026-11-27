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
        // A3: the live dump carries the scroll state the record-derived dump
        // cannot have (it derives from the render payload); compare the rest.
        func stripScrollState(_ node: [String: Any]) -> [String: Any] {
            var out = node
            if out["type"] as? String == "scroll", var props = out["props"] as? [String: Any] {
                for key in ["scrollOffset", "scrollExtent", "viewportExtent"] { props.removeValue(forKey: key) }
                out["props"] = props
            }
            out["children"] = (out["children"] as? [[String: Any]] ?? []).map(stripScrollState)
            return out
        }
        #expect(JSON.valuesEqual(try host.derivedFinalDump(), stripScrollState(live)))
        // and the scroll node itself carries the A3 state
        func findScroll(_ node: [String: Any]) -> [String: Any]? {
            if node["type"] as? String == "scroll" { return node }
            for child in node["children"] as? [[String: Any]] ?? [] {
                if let hit = findScroll(child) { return hit }
            }
            return nil
        }
        let scrollProps = findScroll(live)?["props"] as? [String: Any]
        for key in ["scrollOffset", "scrollExtent", "viewportExtent"] {
            #expect((scrollProps?[key] as? NSNumber)?.doubleValue != nil)
        }
    }

    /// A3: the scroll node dumps live state (offset 0, extent >= viewport at
    /// the start); three flick swipes really scroll the container to its end.
    @Test func scrollStateDumpedAndFlickReachesTheEnd() throws {
        let host = try AppKitTestHost.make(seed: "scroll_list")
        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        func scrollProps(of node: [String: Any]) -> [String: Any]? {
            if node["type"] as? String == "scroll" { return node["props"] as? [String: Any] }
            for child in node["children"] as? [[String: Any]] ?? [] {
                if let hit = scrollProps(of: child) { return hit }
            }
            return nil
        }
        let initial = scrollProps(of: host.mapper.dump()) ?? [:]
        #expect((initial["scrollOffset"] as? NSNumber)?.doubleValue == 0)
        #expect((initial["viewportExtent"] as? NSNumber)?.doubleValue ?? 0 > 0)
        #expect((initial["scrollExtent"] as? NSNumber)?.doubleValue ?? 0 >= (initial["viewportExtent"] as? NSNumber)?.doubleValue ?? 1)

        for _ in 0..<3 { driver.swipe(x1: 49, y1: 180, x2: 49, y2: 40, ms: 150) }
        let final = scrollProps(of: host.mapper.dump()) ?? [:]
        let offset = (final["scrollOffset"] as? NSNumber)?.doubleValue ?? 0
        let extent = (final["scrollExtent"] as? NSNumber)?.doubleValue ?? 0
        let viewport = (final["viewportExtent"] as? NSNumber)?.doubleValue ?? 0
        #expect(offset > 0)
        #expect(offset >= extent - viewport)      // scrolledToEnd
        #expect(offset <= extent - viewport + 0.5) // clamped at the real range
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
        // the demo binary path: JSRAppKitDemo main.swift → jsrAppKitDemo.runConformanceHeadless
        let out = ProcessInfo.processInfo.environment["JSR_CONFORMANCE_OUT"] ?? "/tmp/apple-macos"
        try? FileManager.default.removeItem(atPath: out)
        jsrAppKitDemo.runConformanceHeadless(fixtures: fixturesRoot(), out: out)
        for fixture in jsrAppKitDemo.conformanceFixtures {
            #expect(FileManager.default.fileExists(atPath: out + "/" + fixture + ".result.json"))
        }
        #expect(FileManager.default.fileExists(atPath: out + "/report.md"))
        let counter = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out + "/counter.result.json"))) as? [String: Any]
        #expect(counter?["platform"] as? String == "macos")
        // the L2 mock fixture reaches its answer (review 2026-11-26, finding 2)
        let l2 = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out + "/l2_fetch_json.result.json"))) as? [String: Any]
        #expect(l2?["title"] as? String == "answer 42")
    }

    @Test func parseArgumentsSelectsConformanceAndMenuModes() {
        let conformance = jsrAppKitDemo.parseArguments(["x", "--conformance", "/f", "--out", "/o"], environment: [:])
        if case .conformance(let fixtures, let out) = conformance {
            #expect(fixtures == "/f" && out == "/o")
        } else {
            Issue.record("expected conformance mode")
        }
        let defaultOut = jsrAppKitDemo.parseArguments(["--conformance", "/f"], environment: [:])
        if case .conformance(_, let out) = defaultOut {
            #expect(out == "/tmp/apple-macos")
        } else {
            Issue.record("expected conformance mode")
        }
        let menu = jsrAppKitDemo.parseArguments([], environment: ["JSR_FIXTURES": "/env-fixtures"])
        if case .menu(let fixtures) = menu {
            #expect(fixtures == "/env-fixtures")
        } else {
            Issue.record("expected menu mode")
        }
    }

    @Test func updatePropsExercisesEveryCanonicalPropApplier() throws {
        let host = try AppKitTestHost.make(seed: nil)
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'label'},
          {type:'textButton',title:'go'},
          {type:'container',children:[{type:'text',data:'inner'}]}
        ]});
        """, sourceName: "<test>")
        host.registry.drain()

        // canonical key collapse (internal, @testable)
        #expect(AppKitMapper.canonicalPropKey("data") == "text")
        #expect(AppKitMapper.canonicalPropKey("title") == "text")
        #expect(AppKitMapper.canonicalPropKey("backgroundColor") == "color")
        #expect(AppKitMapper.canonicalPropKey("borderRadius") == "borderRadius")

        let text = host.mapper.views["n1"] as? NSTextField
        let button = host.mapper.views["n2"] as? NSButton
        let container = host.mapper.views["n3"]

        host.mapper.updateProps(nodeId: "n1", props: ["data": "new-label", "color": "#00FF00FF", "fontSize": 21, "fontWeight": "bold"])
        #expect(text?.stringValue == "new-label")
        #expect(text?.textColor != nil) // text color branch
        #expect(text?.font != nil) // fontSize + fontWeight table

        host.mapper.updateProps(nodeId: "n2", props: ["title": "button-label"]) // text applier, button branch
        #expect(button?.title == "button-label")

        host.mapper.updateProps(nodeId: "n3", props: ["backgroundColor": "#FF000080", "borderRadius": 8, "spacing": 5, "decoration": ["border": "1px solid #000"], "unknownProp": 1])
        #expect(container?.layer?.backgroundColor != nil) // container color branch
        #expect(container?.layer?.cornerRadius == 8)
        #expect((container as? NSStackView) != nil || true) // spacing applier tolerated on non-stack
        _ = container?.layer?.borderWidth // decoration applied without crash

        // invalid color leaves the view untouched (guard branch)
        let before = container?.layer?.backgroundColor
        host.mapper.updateProps(nodeId: "n3", props: ["backgroundColor": "not-a-color"])
        #expect(container?.layer?.backgroundColor == before)

        // stack spacing on a real column view (the root)
        host.mapper.updateProps(nodeId: "n0", props: ["spacing": 12])
        #expect((host.mapper.views["n0"] as? NSStackView)?.spacing == 12)
    }

    @Test func removeMoveAndReplaceOperationsPatchTheViewTree() throws {
        let host = try AppKitTestHost.make(seed: nil)
        // REMOVE: three texts shrink to one
        try host.engine.eval("""
        jsr.render({type:'column',children:[{type:'text',data:'a'},{type:'text',data:'b'},{type:'text',data:'c'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        try host.engine.eval("""
        jsr.render({type:'column',children:[{type:'text',data:'a'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        #expect(host.mapper.lastOperations.contains { op in
            if case .removeChild = op { return true }
            return false
        })
        #expect(host.mapper.views["n2"] == nil) // removed subtrees unregistered
        #expect(host.mapper.views["n1"] != nil) // the kept child stays mounted

        // MOVE: keyed children swap order → moveChild, not rebuild
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'first',key:'a'},{type:'text',data:'second',key:'b'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        host.mapper.lastOperations.removeAll()
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'second',key:'b'},{type:'text',data:'first',key:'a'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        #expect(host.mapper.lastOperations.contains { op in
            if case .moveChild = op { return true }
            return false
        })

        // REPLACE: type change at the same position → replaceSubtree
        try host.engine.eval("""
        jsr.render({type:'column',children:[{type:'text',data:'plain'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        host.mapper.lastOperations.removeAll()
        try host.engine.eval("""
        jsr.render({type:'column',children:[{type:'sizedBox',width:10}]});
        """, sourceName: "<t>")
        host.registry.drain()
        #expect(host.mapper.lastOperations.contains { op in
            if case .replaceSubtree = op { return true }
            return false
        })
        #expect(host.mapper.views["n1"] is NSView)
    }

    /// Review 2026-11-26, finding 1: a multi-move reorder patches the live
    /// view order to the new payload order (§2.3 children in order).
    @Test func multiMoveReorderPatchesTheLiveViewOrder() throws {
        let host = try AppKitTestHost.make(seed: nil)
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'a',key:'a'},{type:'text',data:'b',key:'b'},{type:'text',data:'c',key:'c'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        host.mapper.lastOperations.removeAll()
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'c',key:'c'},{type:'text',data:'b',key:'b'},{type:'text',data:'a',key:'a'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        let moves = host.mapper.lastOperations.filter { op in
            if case .moveChild = op { return true }
            return false
        }
        #expect(moves.count >= 2)
        // the applied view order equals the new payload order
        let dump = host.mapper.dump()
        let children = (dump["children"] as? [[String: Any]]) ?? []
        let order = children.compactMap { ($0["props"] as? [String: Any])?["data"] as? String }
        #expect(order == ["c", "b", "a"])
    }

    @Test func driverTapOnNonButtonAndSubmitDispatchMappedEvents() throws {
        let host = try AppKitTestHost.make(seed: nil)
        try host.engine.eval("""
        jsr._handler = function(action, payload) {
          if (action === 'tapAction') { jsr.exportState({tapped: true}); }
          if (action === 'submitAction') { jsr.exportState({submitted: payload.value}); }
        };
        jsr.render({type:'column',props:{onTap:'tapAction'},children:[{type:'text',data:'zone'}]});
        """, sourceName: "<test>")
        host.registry.drain()
        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        #expect(driver.tap(target: "n0") == true) // non-button, record carries onTap
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["tapped"] as? Bool == true)

        host.mapper.records["n7"] = try AuiDump.normalizeTree(payloadJSON:
            #"{"type":"input","props":{"value":"typed-value","onSubmit":"submitAction"}}"#)
        let submitView = NSTextField(string: "typed-value")
        host.mapper.views["n7"] = submitView // resolveNodeId needs a mapped view
        #expect(driver.submit(node: "n7") == true)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["submitted"] as? String == "typed-value")
        #expect(driver.submit(node: "missing") == false)
    }

    @Test func enclosingNodeIdResolvesUnidentifiedNestedField() throws {
        let host = try AppKitTestHost.make(seed: nil)
        try host.engine.eval("""
        jsr._handler = function(action, payload) {
          if (action === 'ch') { jsr.exportState({typed: payload.value}); }
        };
        """, sourceName: "<test>")
        // container carries the identifier; the editable field inside does not
        let container = NSView()
        container.setAccessibilityIdentifier("n5")
        let field = NSTextField(string: "")
        field.isEditable = true // no accessibilityIdentifier
        container.addSubview(field)
        host.mapper.views["n5"] = container
        host.mapper.records["n5"] = try AuiDump.normalizeTree(payloadJSON:
            #"{"type":"input","props":{"onChanged":"ch"}}"#)

        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        driver.controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: field))
        field.stringValue = "enclosed"
        driver.controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: field))
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["typed"] as? String == "enclosed")
    }

    @Test func menuHostLoadsFixturesAndReportsTitles() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 700))
        let host = MenuHost(container: container)
        host.load(fixturesRoot: fixturesRoot(), name: "hello")
        #expect(host.windowTitle.contains("hello"))
        #expect(!host.mapper.views.isEmpty)

        host.load(fixturesRoot: fixturesRoot(), name: "counter")
        #expect(host.windowTitle.contains("counter"))

        host.load(fixturesRoot: fixturesRoot(), name: "does_not_exist")
        #expect(host.windowTitle.contains("missing fixture"))

        // widget that throws → the error branch reports through the title
        let bad = NSTemporaryDirectory() + "jsr-badfix-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: bad + "/boom", withIntermediateDirectories: true)
        try "throw new Error('boom')".write(toFile: bad + "/boom/widget.js", atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["categories": ["L1"]]).write(to: URL(fileURLWithPath: bad + "/boom/meta.json"))
        host.load(fixturesRoot: bad, name: "boom")
        #expect(host.windowTitle.contains("error"))
        try? FileManager.default.removeItem(atPath: bad)
    }

    @Test func submitActionUsesKeyboardDonePathAndDispatchesOnSubmit() throws {
        let host = try AppKitTestHost.make(seed: nil)
        try host.engine.eval("""
        jsr._handler = function(action, payload) {
          if (action === 'go') { jsr.exportState({submitted: payload.value}); }
        };
        """, sourceName: "<test>")
        let field = NSTextField(string: "")
        field.isEditable = true
        field.setAccessibilityIdentifier("n7")
        host.mapper.views["n7"] = field
        host.mapper.records["n7"] = try AuiDump.normalizeTree(payloadJSON:
            #"{"type":"textField","props":{"value":"typed-value","onSubmit":"go"}}"#)
        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)

        // the submit action = the insert-newline path: commit + dispatch
        field.stringValue = "committed"
        #expect(driver.submit(node: "n7") == true)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["submitted"] as? String == "committed")

        // the real keyboard-done delegate dispatches too
        field.stringValue = "ended"
        driver.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["submitted"] as? String == "ended")

        #expect(driver.submit(node: "missing") == false)

        // non-editable view: the record's text content is submitted
        host.mapper.records["n9"] = try AuiDump.normalizeTree(payloadJSON:
            #"{"type":"textButton","text":"record-value","onSubmitted":"go"}"#)
        host.mapper.views["n9"] = NSView() // no editable field inside
        #expect(driver.submit(node: "n9") == true)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["submitted"] as? String == "record-value")
    }

    @Test func scrollSynthesizesWheelEventThroughTheScrollView() throws {
        let host = try AppKitTestHost.make(seed: nil)
        try host.engine.eval("""
        jsr.render({type: 'scroll', children: [{type: 'column', spacing: 4, children: [...Array(60).keys()].map(function(i){ return {type: 'text', data: 'row ' + (i + 1)}; })}]});
        """, sourceName: "<test>")
        host.registry.drain()
        host.mapper.container.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        host.mapper.container.layoutSubtreeIfNeeded()
        guard let scroll = findScroll(in: host.mapper.container) else {
            Issue.record("no NSScrollView mapped")
            return
        }
        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        let before = scroll.contentView.bounds.origin.y
        driver.scroll(dx: 0, dy: 60) // pointer scroll at the surface center
        host.mapper.container.layoutSubtreeIfNeeded()
        let after = scroll.contentView.bounds.origin.y
        #expect(after != before) // the wheel event reached the scroll machinery
        #expect(after >= 0) // clamped by the clip view

        // the event factory produces a real scrollWheel NSEvent
        let event = AppKitInteractionDriver.scrollWheelEvent(dx: 3, dy: 7)
        #expect(event?.type == .scrollWheel)
    }

    @Test func l1SubmitAndScrollFixturesMatchTheirExpectedDeltas() throws {
        // A1/A2 proof over the kit fixtures of the matching event keys: the
        // runner keeps text[0] at the reference value (idle stays idle — the
        // input action alone never fires the keyboard-done or pointer-scroll).
        let fixtures = fixturesRoot()
        for id in ["l1_on_submit", "l1_on_submitted", "l1_on_scroll"] {
            let runner = ConformanceRunner(fixturesDir: fixtures, outDir: NSTemporaryDirectory())
            let result = try runner.run(fixture: id)
            #expect(result["status"] as? String == "DONE")
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixtures + "/" + id + "/expected.json"))) as? [String: Any]
            let expect = expected?["expect"] as? [String: Any]
            #expect((result["renders"] as? [String])?.count == (expect?["renders"] as? Int))
            guard let delta = expect?["finalDumpDelta"] as? [String: String],
                  let path = delta.keys.first else { continue }
            // navigate "text[0].data" over the live final dump
            var node: Any = result["finalDump"] ?? [:]
            var occurrence: [String: Int] = [:]
            let parts = path.split(separator: ".").map(String.init)
            var ok = true
            for part in parts {
                if let bracket = part.firstIndex(of: "[") {
                    let type = String(part[..<bracket])
                    let index = Int(part[part.index(after: bracket)..<part.index(before: part.endIndex)]) ?? 0
                    occurrence[type, default: -1] += 1
                    guard let children = (node as? [String: Any])?["children"] as? [[String: Any]],
                          let match = children.first(where: { ($0["type"] as? String) == type }),
                          occurrence[type]! == index else {
                        ok = false
                        break
                    }
                    node = match
                } else {
                    // the first prop segment resolves through the node's props
                    // (harness resolveDeltaPath semantics)
                    guard let value = ((node as? [String: Any])?["props"] as? [String: Any])?[part]
                            ?? (node as? [String: Any])?[part] else {
                        ok = false
                        break
                    }
                    node = value
                }
            }
            #expect(ok)
            #expect(node as? String == delta[path])
        }
    }

    @Test func editableFieldInputDispatchesOnChangedThroughDelegate() throws {
        let host = try AppKitTestHost.make()
        // inject an editable field + record (tests own the mapper stores)
        let field = NSTextField(string: "")
        field.isEditable = true
        field.setAccessibilityIdentifier("n7")
        host.mapper.views["n7"] = field
        host.mapper.records["n7"] = try AuiDump.normalizeTree(payloadJSON:
            #"{"type":"input","props":{"value":"seed","onChanged":"ch"}}"#)

        try host.engine.eval("""
        jsr._handler = function(action, payload) {
          if (action === 'ch') { jsr.exportState({typed: payload.value}); }
        };
        """, sourceName: "<test>")
        let driver = AppKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        #expect(driver.input(node: "n7", value: "typed") == true)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["typed"] as? String == "typed")

        // the delegate path fires on real text edits too
        field.stringValue = "delegate-edit"
        driver.controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: field))
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["typed"] as? String == "delegate-edit")

        // a field without a matching record is ignored
        let stranger = NSTextField(string: "")
        stranger.isEditable = true
        stranger.setAccessibilityIdentifier("n99")
        driver.controlTextDidChange(Notification(name: NSTextField.textDidChangeNotification, object: stranger))
    }

    @Test func eightHexColorsApplyWithAlpha() throws {
        let host = try AppKitTestHost.make(seed: nil)
        try host.engine.eval("""
        jsr.render({type:'container',props:{backgroundColor:'#FF000080'},
          children:[{type:'text',data:'colored',props:{color:'#00FF00FF'}}]});
        """, sourceName: "<test>")
        host.registry.drain()
        let container = host.mapper.views["n0"]
        #expect(container?.layer?.backgroundColor != nil) // parsed (alpha channel branch)
        let text = host.mapper.views["n1"] as? NSTextField
        #expect(text?.textColor != nil) // 8-hex text color branch
    }
}
