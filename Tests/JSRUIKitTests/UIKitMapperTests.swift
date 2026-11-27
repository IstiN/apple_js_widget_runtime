#if canImport(UIKit) && os(iOS)
import UIKit
import Testing
import JSRCore
@testable import JSRUIKit
@testable import JSRUIDemo

// UIKit mapping and conformance with real UIKit views, hosted in the demo
// application window (issue #2). Runs in the CI `ios` job (XcodeGen project).

private func fixturesRoot() -> String {
    // Tests/JSRUIKitTests/UIKitMapperTests.swift -> package root (the checkout
    // exists on the CI runner; the app and test target share the same volume)
    let file = URL(fileURLWithPath: #filePath)
    return file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        + "/.conformance/js_widget_runtime/docs/conformance/fixtures"
}

// Same scaffolding as the AppKit suite's AppKitTestHost, on UIKit views.
@MainActor
private struct UIKitTestHost {
    let mapper: UIKitMapper
    let runtime: JsWidgetRuntime
    let registry: ChannelRegistry
    let engine: JsContextEngine
    let timers: ManualTimerDriver

    static func make() throws -> UIKitTestHost {
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        let timers = ManualTimerDriver()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        let mapper = UIKitMapper(container: container)
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
        }, iid: "ios")
        return UIKitTestHost(mapper: mapper, runtime: runtime, registry: registry, engine: engine, timers: timers)
    }
}

@Suite @MainActor struct UIKitMapperTests {
    @Test func helloMapsToUIKitViewsWithNodeIds() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        let mapper = UIKitMapper(container: container)
        try mapper.render(payloadJSON: """
        {"type":"center","child":{"type":"column","spacing":8,"children":[
          {"type":"text","data":"Hello"},
          {"type":"textButton","text":"Tap me"}]}}
        """)
        #expect(container.subviews.count == 1)
        let center = container.subviews[0]
        #expect(center.accessibilityIdentifier == "n0")
        #expect(mapper.views["n0"] != nil && mapper.views["n1"] != nil)
        // depth-first pre-order: n0 center, n1 column, n2 text, n3 textButton
        #expect((mapper.views["n2"] as? UILabel)?.text == "Hello")
        #expect(mapper.views["n3"] is UIButton)
        #expect((mapper.views["n3"] as? UIButton)?.title(for: .normal) == "Tap me")
        #expect(center.subviews.first is UIStackView)
    }

    @Test func dumpOfRealViewsMatchesTheDerivedTree() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        let mapper = UIKitMapper(container: container)
        let payload = """
        {"type":"column","children":[
          {"type":"text","data":"Hello"},
          {"type":"sizedBox","height":12},
          {"type":"textButton","text":"Tap me"}]}
        """
        try mapper.render(payloadJSON: payload)
        container.layoutIfNeeded()
        let live = mapper.dump()
        let derived = try AuiDump.normalizeTree(payloadJSON: payload).jsonObject
        #expect(JSON.valuesEqual(derived, live))
    }

    @Test func counterTapsPatchWithoutRebuild() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 420, height: 700))
        let mapper = UIKitMapper(container: container)
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        let timers = ManualTimerDriver()
        weak var registryRef: ChannelRegistry?
        let registry = ChannelRegistry(services: HostServices(),
                                       timers: Timers(driver: timers, evaluate: { _ in }),
                                       configuration: JSRConfiguration()) { _ in }
        registryRef = registry
        mapper.onEvent = { actionId, payloadJson in
            try? runtime.callEvent(actionId, payloadJson: payloadJson)
        }
        try runtime.start(sink: { channel, payload in
            registry.dispatch(channel: channel, payload: payload)
            if channel == "__jsr_render" {
                try? mapper.render(payloadJSON: payload)
            }
        }, iid: "ios")
        try engine.eval("""
        var taps = 0;
        jsr._handler = function(action) {
          if (action === 'tap') { taps += 1; jsr.render({type:'column',children:[{type:'text',data:String(taps)},{type:'textButton',text:'+1',onTap:'tap'}]}); }
        };
        jsr.render({type:'column',children:[{type:'text',data:'0'},{type:'textButton',text:'+1',onTap:'tap'}]});
        """, sourceName: "counter")
        registry.drain()
        let driver = UIKitInteractionDriver(mapper: mapper, runtime: runtime, registry: registry, engine: engine)
        #expect(driver.tap(target: "+1"))
        registry.drain()
        #expect(mapper.lastOperations.count == 1) // one updateProps — patch, not rebuild
        guard case let .updateProps(nodeId, props)? = mapper.lastOperations.first else {
            Issue.record("expected updateProps")
            return
        }
        #expect((props["data"] as? String) == "1")
        _ = nodeId
    }

    @Test func conformanceSeedsPassWithRealViews() throws {
        // the iOS results for the harness (platform "ios"); written under the
        // app container's tmp/jsr-ios so the CI job can collect them
        let out = NSTemporaryDirectory() + "jsr-ios"
        jsrUIKitConformance.run(fixtures: fixturesRoot(), out: out)
        for fixture in jsrUIKitConformanceFixtures {
            #expect(FileManager.default.fileExists(atPath: out + "/" + fixture + ".result.json"))
        }
        let counter = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out + "/counter.result.json"))) as? [String: Any]
        #expect(counter?["platform"] as? String == "ios")
        // the L2 mock fixture reaches its answer (review 2026-11-26, finding 2)
        let l2 = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out + "/l2_fetch_json.result.json"))) as? [String: Any]
        #expect(l2?["title"] as? String == "answer 42")
    }

    @Test func propPatchesExerciseEveryCanonicalApplier() throws {
        let host = try UIKitTestHost.make()
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'label'},
          {type:'textButton',text:'go'},
          {type:'container',children:[{type:'text',data:'inner'}]}
        ]});
        """, sourceName: "<test>")
        host.registry.drain()

        // canonical key collapse (internal, @testable)
        #expect(UIKitMapper.canonicalPropKey("data") == "text")
        #expect(UIKitMapper.canonicalPropKey("title") == "text")
        #expect(UIKitMapper.canonicalPropKey("backgroundColor") == "color")
        #expect(UIKitMapper.canonicalPropKey("borderRadius") == "borderRadius")

        let text = host.mapper.views["n1"] as? UILabel
        let button = host.mapper.views["n2"] as? UIButton
        let container = host.mapper.views["n3"]

        host.mapper.updateProps(nodeId: "n1", props: ["data": "new-label", "color": "#00FF00FF", "fontSize": 21, "fontWeight": "bold"])
        #expect(text?.text == "new-label")
        #expect(text?.textColor != nil) // color applier, label branch
        #expect(text?.font != nil) // fontSize + fontWeight table

        host.mapper.updateProps(nodeId: "n2", props: ["title": "button-label"]) // text applier, button branch
        #expect(button?.title(for: .normal) == "button-label")

        host.mapper.updateProps(nodeId: "n3", props: ["backgroundColor": "#FF000080", "borderRadius": 8, "spacing": 5, "decoration": ["border": "1px solid #000"], "unknownProp": 1])
        #expect(container?.layer.backgroundColor != nil) // container color branch
        #expect(container?.layer.cornerRadius == 8)
        _ = container?.layer.borderWidth // decoration applied without crash

        // invalid color leaves the view untouched (guard branch)
        let before = container?.layer.backgroundColor
        host.mapper.updateProps(nodeId: "n3", props: ["backgroundColor": "not-a-color"])
        #expect(container?.layer.backgroundColor == before)

        // stack spacing on a real column view (the root)
        host.mapper.updateProps(nodeId: "n0", props: ["spacing": 12])
        #expect((host.mapper.views["n0"] as? UIStackView)?.spacing == 12)
    }

    @Test func removeMoveInsertAndReplaceOperationsPatchTheViewTree() throws {
        let host = try UIKitTestHost.make()
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

        // INSERT: an appended child mounts without a rebuild
        host.mapper.lastOperations.removeAll()
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'second',key:'b'},{type:'text',data:'first',key:'a'},{type:'text',data:'third',key:'c'}]});
        """, sourceName: "<t>")
        host.registry.drain()
        #expect(host.mapper.lastOperations.contains { op in
            if case .insertChild = op { return true }
            return false
        })
        #expect(host.mapper.views.count >= 4)

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
        #expect(host.mapper.views["n1"] is UIView)
    }

    /// Review 2026-11-26, finding 1: a multi-move reorder patches the live
    /// view order to the new payload order (§2.3 children in order).
    @Test func multiMoveReorderPatchesTheLiveViewOrder() throws {
        let host = try UIKitTestHost.make()
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

    @Test func editableFieldInputDispatchesOnChanged() throws {
        let host = try UIKitTestHost.make()
        try host.engine.eval("""
        jsr._handler = function(action, payload) {
          if (action === 'ch') { jsr.exportState({typed: payload.value}); }
        };
        jsr.render({type:'textField',value:'seed',onChanged:'ch'});
        """, sourceName: "<test>")
        host.registry.drain()
        let field = host.mapper.views["n0"] as? UITextField // buildEditableField
        #expect(field?.text == "seed")
        let driver = UIKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        #expect(driver.input(node: "n0", value: "typed") == true)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["typed"] as? String == "typed")

        // the real editing path fires through the target/action too
        field?.text = "target-action-edit"
        field?.sendActions(for: .editingChanged)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["typed"] as? String == "target-action-edit")
    }

    @Test func submitUsesTheReturnKeyPathAndDispatchesOnSubmit() throws {
        let host = try UIKitTestHost.make()
        try host.engine.eval("""
        jsr._handler = function(action, payload) {
          if (action === 'go') { jsr.exportState({submitted: payload.value}); }
        };
        jsr.render({type:'textField',value:'typed-value',onSubmit:'go'});
        """, sourceName: "<test>")
        host.registry.drain()
        let field = host.mapper.views["n0"] as? UITextField
        #expect(field?.text == "typed-value")
        let driver = UIKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)

        // the submit action = the return-key path: commit + dispatch
        field?.text = "committed"
        #expect(driver.submit(node: "n0") == true)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["submitted"] as? String == "committed")

        // the real keyboard-done delegate dispatches too
        field?.text = "ended"
        if let field {
            #expect(driver.textFieldShouldReturn(field) == true)
        }
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["submitted"] as? String == "ended")

        #expect(driver.submit(node: "missing") == false)

        // non-editable view: the record's text content is submitted
        host.mapper.records["n9"] = try AuiDump.normalizeTree(payloadJSON:
            #"{"type":"textButton","text":"record-value","onSubmitted":"go"}"#)
        host.mapper.views["n9"] = UIView() // no editable field inside
        #expect(driver.submit(node: "n9") == true)
        host.registry.drain()
        #expect((host.registry.recorder.state as? [String: Any])?["submitted"] as? String == "record-value")
    }

    @Test func driverTapCoversNonButtonAliasesAndMissingTargets() throws {
        let host = try UIKitTestHost.make()
        var events: [String] = []
        host.mapper.onEvent = { actionId, _ in events.append(actionId) }
        try host.engine.eval("""
        jsr.render({type:'column',children:[
          {type:'text',data:'one',onTap:'t1'},
          {type:'text',data:'two',onClick:'t2'},
          {type:'text',data:'three'}
        ]});
        """, sourceName: "<test>")
        host.registry.drain()
        let driver = UIKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        #expect(driver.tap(target: "n1") == true) // non-button with onTap
        #expect(events.contains("t1"))
        #expect(driver.tap(target: "n2") == true) // onClick alias
        #expect(events.contains("t2"))
        #expect(driver.tap(target: "n3") == true) // mapped, no events
        #expect(driver.tap(target: "missing") == false)
    }

    @Test func currentTreeReturnsTheRootRecord() throws {
        let host = try UIKitTestHost.make()
        try host.engine.eval("""
        jsr.render({type:'center',children:[{type:'text',data:'x'}]});
        """, sourceName: "<test>")
        host.registry.drain()
        let driver = UIKitInteractionDriver(mapper: host.mapper, runtime: host.runtime, registry: host.registry, engine: host.engine)
        #expect(driver.currentTree()?.type == "center")
    }
}
#endif
