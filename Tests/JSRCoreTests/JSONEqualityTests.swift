import Foundation
import Testing
@testable import JSRCore

// JSON.valuesEqual branch coverage: scalar crosses, array/dict mismatches.

@Suite struct JSONEqualityTests {
    @Test func scalarsCompareExactlyAndNeverAcrossKinds() {
        #expect(JSON.valuesEqual("a", "a"))
        #expect(!JSON.valuesEqual("a", "b"))
        #expect(JSON.valuesEqual(true, true))
        #expect(!JSON.valuesEqual(true, false))
        #expect(JSON.valuesEqual(5, 5))
        #expect(!JSON.valuesEqual(5, 6))
        #expect(JSON.valuesEqual(NSNull(), NSNull()))
        // bool never equals a number (either side)
        #expect(!JSON.valuesEqual(true, 1))
        #expect(!JSON.valuesEqual(1, true))
        // string never equals a number or bool
        #expect(!JSON.valuesEqual("1", 1))
        #expect(!JSON.valuesEqual("true", true))
        // NSNull never equals a value
        #expect(!JSON.valuesEqual(NSNull(), 0))
    }

    @Test func arraysAndDictsNeedMatchingShapes() {
        #expect(JSON.valuesEqual([1, 2], [1, 2]))
        #expect(!JSON.valuesEqual([1, 2], [1, 2, 3]))
        #expect(!JSON.valuesEqual([1, 2], [1]))
        #expect(JSON.valuesEqual(["a": 1, "b": 2], ["b": 2, "a": 1]))
        #expect(!JSON.valuesEqual(["a": 1], ["a": 2]))
        #expect(!JSON.valuesEqual(["a": 1], ["b": 1]))
        #expect(!JSON.valuesEqual(["a": 1], ["a": 1, "b": 2]))
        #expect(!JSON.valuesEqual([1, 2], "not an array"))
        #expect(!JSON.valuesEqual(["a": 1], 42))
    }
}
