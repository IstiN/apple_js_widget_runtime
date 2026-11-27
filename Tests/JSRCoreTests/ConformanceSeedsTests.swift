import Testing
import Foundation
@testable import JSRCore

// Conformance run of the seeds with the tree-level driver (issue #1):
// boots the real halves, applies expected.json actions, writes result.json
// to JSR_CONFORMANCE_OUT (default /tmp/apple-host); harness compare consumes it.
@Suite struct ConformanceSeedsTests {
    private func runFixture(_ id: String) throws -> [String: Any] {
        let runner = ConformanceRunner(fixturesDir: TestHost.fixturesDir(), outDir: TestHost.conformanceOutDir())
        return try runner.run(fixture: id)
    }

    @Test func helloRunsAndInteracts() throws {
        let result = try runFixture("hello")
        #expect(result["status"] as? String == "DONE")
        #expect((result["renders"] as? [String])?.count == 2)
        #expect(result["title"] as? String == "Tapped: 1")
        let trace = result["trace"] as? [String] ?? []
        #expect(trace.contains("render"))
        #expect(trace.contains("set_title"))

        let finalDump = result["finalDump"] as? [String: Any]
        let children = finalDump?["children"] as? [[String: Any]]
        let column = children?.first?["children"] as? [[String: Any]]
        let secondText = column?[1]
        #expect((secondText?["props"] as? [String: Any])?["data"] as? String == "Taps: 1")
    }

    @Test func counterRunsAndInteracts() throws {
        let result = try runFixture("counter")
        #expect(result["status"] as? String == "DONE")
        #expect((result["renders"] as? [String])?.count == 4) // initial + +1 + +1 + -1
        let finalDump = result["finalDump"] as? [String: Any]
        let children = finalDump?["children"] as? [[String: Any]]
        let column = children?.first?["children"] as? [[String: Any]]
        let countText = column?[1]
        #expect((countText?["props"] as? [String: Any])?["data"] as? String == "1")
    }

    @Test func resultsAreWrittenForHarnessCompare() throws {
        let outDir = TestHost.conformanceOutDir()
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        _ = try runFixture("hello")
        _ = try runFixture("counter")
        #expect(FileManager.default.fileExists(atPath: outDir + "/hello.result.json"))
        #expect(FileManager.default.fileExists(atPath: outDir + "/counter.result.json"))
    }

    /// Review 2026-11-26, finding 2: `__JSR_MOCK_ORIGIN__` is injected before
    /// the widget, so the pinned mock fixture reaches `answer 42` on the host.
    @Test func l2FetchJsonReachesTheMockAnswer() throws {
        let result = try runFixture("l2_fetch_json")
        #expect(result["status"] as? String == "DONE")
        #expect(result["title"] as? String == "answer 42")
        #expect((result["renders"] as? [String])?.count == 1)
        let trace = result["trace"] as? [String] ?? []
        #expect(trace.contains("fetch"))
        #expect(trace.contains("set_title"))
        let finalDump = result["finalDump"] as? [String: Any]
        let children = finalDump?["children"] as? [[String: Any]]
        let column = children?.first?["children"] as? [[String: Any]]
        #expect((column?.first?["props"] as? [String: Any])?["data"] as? String == "answer 42")
    }

    @Test func unsupportedCapabilitySkipsWithReason() throws {
        // Build a one-off fixture directory with a capability the host lacks.
        let root = NSTemporaryDirectory() + "jsr-skip-fixture-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try "jsr.render({type: 'text', data: 'x'});".write(toFile: root + "/widget.js", atomically: true, encoding: .utf8)
        try #"{"categories": ["L3"], "capabilities": ["three"], "ignore": [], "mock": {}}"#.write(toFile: root + "/meta.json", atomically: true, encoding: .utf8)
        try "{}".write(toFile: root + "/expected.json", atomically: true, encoding: .utf8)
        let fixtures = NSTemporaryDirectory() + "jsr-skip-fixtures-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: fixtures + "/skip_me", withIntermediateDirectories: true)
        for file in ["widget.js", "meta.json", "expected.json"] {
            try FileManager.default.copyItem(atPath: root + "/" + file, toPath: fixtures + "/skip_me/" + file)
        }
        let outDir = NSTemporaryDirectory() + "jsr-skip-out-\(UUID().uuidString)"
        let runner = ConformanceRunner(fixturesDir: fixtures, outDir: outDir)
        let result = try runner.run(fixture: "skip_me")
        #expect(result["status"] as? String == "SKIP")
        #expect((result["skippedReason"] as? String)?.hasPrefix("unsupported capability") == true)
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: fixtures)
        try? FileManager.default.removeItem(atPath: outDir)
    }
}
