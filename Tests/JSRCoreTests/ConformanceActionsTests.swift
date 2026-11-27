import Foundation
import Testing
@testable import JSRCore

// Every action kind of expected.json drives its apply* branch (plan 1.4
// action list); a recording driver proves the dispatch. Also: runAll(filter:)
// and the tree driver's input path.

private func makeFixture(id: String, actions: [[String: Any]], in root: String) throws {
    let dir = root + "/" + id
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let widget = "jsr.render({type:'column',children:[{type:'text',data:'actions-synthetic'}]});"
    try widget.write(toFile: dir + "/widget.js", atomically: true, encoding: .utf8)
    let meta: [String: Any] = ["categories": ["L1"], "capabilities": [], "nodes": ["column", "text"]]
    try JSONSerialization.data(withJSONObject: meta).write(to: URL(fileURLWithPath: dir + "/meta.json"))
    let expected: [String: Any] = ["expect": ["renders": 1], "actions": actions]
    try JSONSerialization.data(withJSONObject: expected).write(to: URL(fileURLWithPath: dir + "/expected.json"))
}

final class RecordingDriver: InteractionDriver {
    private(set) var calls: [String] = []

    func currentTree() -> WidgetNode? { nil }
    func tap(target: String) -> Bool { calls.append("tap:\(target)"); return true }
    func input(node: String, value: String) -> Bool { calls.append("input:\(node)=\(value)"); return true }
    func submit(node: String) -> Bool { calls.append("submit:\(node)"); return true }
    func scroll(dx: Double, dy: Double) { calls.append("scroll:\(dx),\(dy)") }
    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, ms: Double) { calls.append("swipe:\(ms)") }
    func wait(ms: Double) { calls.append("wait:\(ms)") } // no real sleep in tests
    func back() { calls.append("back") }
}

@Suite struct ConformanceActionsTests {
    @Test func everyActionKindReachesItsDriverMethod() throws {
        let root = NSTemporaryDirectory() + "jsr-actions-\(UUID().uuidString)"
        try makeFixture(id: "actions_synthetic", actions: [
            ["tap": "n1"],
            ["input": ["node": "n1", "value": "typed"]],
            ["submit": "n1"],
            ["scroll": [3, 7]],
            ["swipe": [0, 0, 10, 20, 40]],
            ["wait": 5],
            ["back": true],
        ], in: root)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let runner = ConformanceRunner(fixturesDir: root, outDir: root)
        let driver = RecordingDriver()
        _ = try runner.run(fixture: "actions_synthetic", driverFactory: { _, _, _, _ in driver })

        #expect(driver.calls.contains("tap:n1"))
        #expect(driver.calls.contains("input:n1=typed"))
        #expect(driver.calls.contains("submit:n1"))
        #expect(driver.calls.contains("scroll:3.0,7.0"))
        #expect(driver.calls.contains("swipe:40.0"))
        #expect(driver.calls.contains("wait:5.0"))
        #expect(driver.calls.contains("back"))
    }

    @Test func malformedActionsAreSkippedWithoutCrashing() throws {
        let root = NSTemporaryDirectory() + "jsr-actions-\(UUID().uuidString)"
        try makeFixture(id: "actions_bad", actions: [
            ["tap": 42],                       // wrong type
            ["scroll": [1]],                   // wrong arity
            ["swipe": [0, 0, 1, 1]],           // wrong arity
            ["wait": "nope"],                  // wrong type
            ["unknown_verb": true],            // falls through to back (falsy)
        ], in: root)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let runner = ConformanceRunner(fixturesDir: root, outDir: root)
        let driver = RecordingDriver()
        _ = try runner.run(fixture: "actions_bad", driverFactory: { _, _, _, _ in driver })
        #expect(driver.calls.isEmpty)
    }

    @Test func runAllRunsEveryFixtureAndFilterSelectsOne() throws {
        let root = NSTemporaryDirectory() + "jsr-actions-\(UUID().uuidString)"
        try makeFixture(id: "aa_one", actions: [], in: root)
        try makeFixture(id: "bb_two", actions: [], in: root)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let runner = ConformanceRunner(fixturesDir: root, outDir: root)
        let all = try runner.runAll() // statuses per fixture
        #expect(all == ["DONE", "DONE"])
        #expect(FileManager.default.fileExists(atPath: root + "/aa_one.result.json"))
        #expect(FileManager.default.fileExists(atPath: root + "/bb_two.result.json"))

        let filteredOut = NSTemporaryDirectory() + "jsr-filtered-\(UUID().uuidString)"
        let filtered = try ConformanceRunner(fixturesDir: root, outDir: filteredOut).runAll(filter: "aa_*")
        #expect(filtered == ["DONE"])
        #expect(FileManager.default.fileExists(atPath: filteredOut + "/aa_one.result.json"))
        #expect(!FileManager.default.fileExists(atPath: filteredOut + "/bb_two.result.json"))
    }

    @Test func runSkipsUnsupportedCapabilityAndCapturesWidgetErrors() throws {
        let root = NSTemporaryDirectory() + "jsr-cap-\(UUID().uuidString)"
        // SKIP branch: capability the host does not support
        let skipDir = root + "/needs_three"
        try FileManager.default.createDirectory(atPath: skipDir, withIntermediateDirectories: true)
        try "jsr.render({type:'text',data:'x'});".write(toFile: skipDir + "/widget.js", atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["categories": ["L2"], "capabilities": ["three"]])
            .write(to: URL(fileURLWithPath: skipDir + "/meta.json"))
        try JSONSerialization.data(withJSONObject: ["expect": [:]]).write(to: URL(fileURLWithPath: skipDir + "/expected.json"))
        // error branch: widget throws
        let errDir = root + "/throws"
        try FileManager.default.createDirectory(atPath: errDir, withIntermediateDirectories: true)
        try "throw new Error('fixture blew up');".write(toFile: errDir + "/widget.js", atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["categories": ["L1"], "capabilities": []])
            .write(to: URL(fileURLWithPath: errDir + "/meta.json"))
        defer { try? FileManager.default.removeItem(atPath: root) }

        let runner = ConformanceRunner(fixturesDir: root, outDir: root)
        let skipped = try runner.run(fixture: "needs_three")
        #expect(skipped["status"] as? String == "SKIP")
        #expect((skipped["skippedReason"] as? String)?.contains("three") == true)

        let failed = try runner.run(fixture: "throws")
        #expect(failed["status"] as? String == "DONE")
        #expect((failed["error"] as? String)?.contains("blew up") == true)

        // missing fixture still throws the named error
        #expect(throws: ConformanceRunnerError.self) { try runner.run(fixture: "nope") }
    }

    @Test func treeDriverInputDispatchesByNodeIdAndByText() throws {
        let host = try TestHost.make()
        try host.eval("""
        jsr._handler = function(action, payload) {
          if (action === 'ch') { jsr.exportState({typed: payload.value}); }
        };
        jsr.render({type:'column',children:[
          {type:'input',value:'seed',onChanged:'ch'},
          {type:'text',data:'label-target'}
        ]});
        """)
        host.registry.drain()
        let driver = TreeInteractionDriver(runtime: host.runtime, recorder: host.recorder,
                                           registry: host.registry, engine: host.engine)
        #expect(driver.input(node: "n1", value: "typed"))
        host.registry.drain()
        let state = host.recorder.state as? [String: Any]
        #expect(state?["typed"] as? String == "typed")

        // tree is available and misses fail cleanly
        #expect(driver.currentTree() != nil)
        #expect(driver.input(node: "missing-node", value: "x") == false)
    }

    /// A3 swipe semantics: the settled content move of a touch flick is the
    /// gesture delta plus the momentum coast (v = delta/ms, rate 0.998/ms);
    /// no duration means no coast.
    @Test func flickCarryAddsTheMomentumCoast() {
        #expect(flickCarry(140, ms: 150) > 140) // a flick carries further than its travel
        let carry = flickCarry(140, ms: 150)
        #expect(abs(carry - (140 + (140.0 / 150.0) * 0.998 / 0.002)) < 0.001)
        #expect(flickCarry(60, ms: 0) == 60) // degenerate gesture: raw delta
        #expect(flickCarry(-90, ms: 100) < -90) // upward flicks coast negative too
    }
}
