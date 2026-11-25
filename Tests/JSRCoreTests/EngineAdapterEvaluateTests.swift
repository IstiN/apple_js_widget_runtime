import Foundation
import Testing
@testable import JSRCore

// JsContextEngine.evaluate conversion branches (test/debug helper, not part
// of the adapter interface).

@Suite struct EngineAdapterEvaluateTests {
    private func makeEngine() -> JsContextEngine { JsContextEngine() }

    @Test func convertsObjectArrayNumberStringBool() {
        let engine = makeEngine()
        #expect((engine.evaluate("({a: 1, b: 'x'})") as? [String: Any])?["a"] != nil)
        #expect((engine.evaluate("([1, 2])") as? [Any])?.count == 2)
        #expect((engine.evaluate("42") as? NSNumber)?.intValue == 42)
        #expect((engine.evaluate("'hello'") as? String) == "hello")
        #expect((engine.evaluate("true") as? Bool) == true)
    }

    @Test func undefinedAndNullBecomeNil() {
        let engine = makeEngine()
        #expect(engine.evaluate("undefined") == nil)
        #expect(engine.evaluate("null") == nil)
    }

    @Test func exceptionBecomesMarkerDict() {
        let engine = makeEngine()
        let value = engine.evaluate("throw new Error('boom')")
        let dict = value as? [String: Any]
        #expect(dict?["__exception"] != nil)
        // engine keeps working after an exception
        #expect((engine.evaluate("1 + 1") as? NSNumber)?.intValue == 2)
    }
}
