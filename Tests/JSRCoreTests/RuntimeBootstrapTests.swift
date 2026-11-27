import Testing
@testable import JSRCore

// Recording JsEngine fake (plan: tests use in-memory fakes, not a live engine).
private final class RecordingEngine: JsEngine {
    struct Eval {
        let code: String
        let sourceName: String
    }

    private(set) var evals: [Eval] = []
    private(set) var pendingJobsRuns = 0
    private(set) var disposed = false
    private var callback: ((_ channel: String, _ payload: String) -> Void)?

    func eval(_ code: String, sourceName: String) throws {
        evals.append(Eval(code: code, sourceName: sourceName))
    }

    func executePendingJobs() {
        pendingJobsRuns += 1
    }

    func dispose() {
        disposed = true
    }

    func setMessageCallback(_ callback: @escaping (_ channel: String, _ payload: String) -> Void) {
        self.callback = callback
    }

    /// Test helper: simulates the JS side calling the `sendMessage` global.
    func deliver(channel: String, payload: String) {
        callback?(channel, payload)
    }
}

@Suite struct RuntimeBootstrapTests {
    @Test func startEvaluatesIidRuntimeHalfWidgetHalfInOrderAndNothingElse() throws {
        let engine = RecordingEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        try runtime.start(sink: { _, _ in }, iid: "test-iid-1")
        #expect(engine.evals.count == 3)
        #expect(engine.evals[0].code == "var __IID = \"test-iid-1\";")
        #expect(engine.evals[0].sourceName == "<iid>")
        #expect(engine.evals[1].sourceName == "bootstrap-runtime.js")
        #expect(engine.evals[1].code.contains("var __cbs"), "runtime half must be the runtime bootstrap")
        #expect(engine.evals[2].sourceName == "bootstrap-widget.js")
        #expect(engine.evals[2].code.contains("Object.assign(jsr"), "widget half must be the widget bootstrap")
    }

    @Test func renderMessageFromEngineReachesRegisteredSink() throws {
        let engine = RecordingEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        var received: [(channel: String, payload: String)] = []
        try runtime.start(sink: { received.append(($0, $1)) }, iid: "i")
        engine.deliver(channel: "__jsr_render", payload: "{\"type\":\"column\"}")
        #expect(received.count == 1)
        #expect(received[0].channel == "__jsr_render")
        #expect(received[0].payload == "{\"type\":\"column\"}")
    }

    @Test func callEventDrainsPendingJobsAndDispose() throws {
        let engine = RecordingEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        try runtime.start(sink: { _, _ in }, iid: "i")
        #expect(engine.pendingJobsRuns == 0)
        try runtime.callEvent("a1", payloadJson: "{}")
        #expect(engine.pendingJobsRuns > 0)
        engine.dispose()
        #expect(engine.disposed)
    }

    /// Review 2026-11-26, finding 6: `__IID` goes through the JSON encoder,
    /// so quotes and backslashes survive the bridge boundary intact.
    @Test func iidWithQuotesAndBackslashesReachesTheEngineIntact() throws {
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        let nasty = "host said \"hi\" and left\\"
        try runtime.start(sink: { _, _ in }, iid: nasty)
        #expect(engine.evaluate("__IID") as? String == nasty)
    }

    /// Same for the actionId of `callEvent` (backslash-quoting used to miss).
    @Test func callEventCarriesQuotesAndBackslashesInTheActionId() throws {
        let engine = JsContextEngine()
        let runtime = JsWidgetRuntime(engine: engine)
        var seen: [(String, String)] = []
        try runtime.start(sink: { seen.append(($0, $1)) }, iid: "i")
        try engine.eval("jsr._handler = function(action, payload) { sendMessage('echo', action); };", sourceName: "<t>")
        let nasty = "tap\"me\\again"
        try runtime.callEvent(nasty, payloadJson: "{}")
        #expect(seen.count == 1)
        #expect(seen.first?.0 == "echo")
        #expect(seen.first?.1 == nasty)
    }
}
