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
        for seed in jsrUIKitDemoSeeds {
            #expect(FileManager.default.fileExists(atPath: out + "/" + seed + ".result.json"))
        }
        let counter = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: out + "/counter.result.json"))) as? [String: Any]
        #expect(counter?["platform"] as? String == "ios")
    }
}
#endif
