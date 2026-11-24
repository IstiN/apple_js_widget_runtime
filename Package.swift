// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppleJSWidgetRuntime",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "JSRCore", targets: ["JSRCore"]),
        .library(name: "JSRUIKit", targets: ["JSRUIKit"]),
        .library(name: "JSRAppKit", targets: ["JSRAppKit"]),
    ],
    targets: [
        // 100% shared: JSC bridge, bootstrap, tree model, reconciler,
        // conformance runner (AUI dump + event trace per PROTOCOL.md)
        .target(name: "JSRCore"),
        // iOS: jsr nodes -> UIKit (UIStackView/UILabel/UIButton/UIScrollView)
        .target(name: "JSRUIKit", dependencies: ["JSRCore"]),
        // macOS: jsr nodes -> AppKit (NSStackView/NSTextField/NSButton/NSScrollView)
        .target(name: "JSRAppKit", dependencies: ["JSRCore"]),
        .testTarget(name: "JSRCoreTests", dependencies: ["JSRCore"]),
    ]
)
