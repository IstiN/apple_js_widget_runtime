#if canImport(UIKit) && os(iOS)
import Testing

// P3: UIKit mapping tests with real views in the iOS demo host (Demo/iOS, XcodeGen).
@Suite struct JSRUIKitTests {
    @Test func targetWired() {
        #expect(Bool(true))
    }
}
#endif
