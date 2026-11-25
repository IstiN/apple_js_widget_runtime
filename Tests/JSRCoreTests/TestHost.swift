import Foundation
@testable import JSRCore

// Shared boot helper: real bootstrap halves on JsContextEngine with the
// ChannelRegistry sink — the exact chain the conformance loop uses.
struct TestHost {
    let engine: JsContextEngine
    let runtime: JsWidgetRuntime
    let registry: ChannelRegistry
    let timers: ManualTimerDriver
    let recorder: HostRecorder

    static func fixtureRoot() -> String {
        // Tests/JSRCoreTests/XCTestCase.swift -> package root
        let file = URL(fileURLWithPath: #filePath)
        return file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }

    static func fixturesDir() -> String {
        fixtureRoot() + "/.conformance/js_widget_runtime/docs/conformance/fixtures"
    }

    static func conformanceOutDir() -> String {
        ProcessInfo.processInfo.environment["JSR_CONFORMANCE_OUT"] ?? "/tmp/apple-host"
    }

    static func make(
        services: HostServices = HostServices(),
        configuration: JSRConfiguration = JSRConfiguration(),
        iid: String = "test-iid"
    ) throws -> TestHost {
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        let timers = ManualTimerDriver()
        weak var registryRef: ChannelRegistry?
        let host = Timers(driver: timers, evaluate: { script in
            try? engine.eval(script, sourceName: "<timer>")
            registryRef?.drain()
        })
        let registry = ChannelRegistry(services: services, timers: host, configuration: configuration) { script in
            try? engine.eval(script, sourceName: "<resolve>")
        }
        registryRef = registry
        try runtime.start(sink: { registry.dispatch(channel: $0, payload: $1) }, iid: iid)
        return TestHost(engine: engine, runtime: runtime, registry: registry, timers: timers, recorder: registry.recorder)
    }

    func eval(_ code: String) throws {
        try engine.eval(code, sourceName: "<test>")
    }

    /// Evaluates an expression and returns the native value.
    func value(of code: String) -> Any? {
        engine.evaluate(code)
    }
}
