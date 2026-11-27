// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppleJSWidgetRuntime",
    platforms: [.iOS(.v13), .macOS(.v11)],
    products: [
        .library(name: "JSRCore", targets: ["JSRCore"]),
        .library(name: "JSRUIKit", targets: ["JSRUIKit"]),
        .library(name: "JSRAppKit", targets: ["JSRAppKit"]),
        .executable(name: "JSRAppKitDemo", targets: ["JSRAppKitDemo"]),
    ],
    targets: [
        // 100% shared: engine adapter (JSC), bootstrap halves (Resources/), tree model,
        // reconciler, conformance runner (AUI dump + event trace per PROTOCOL.md)
        .target(
            name: "JSRCore",
            resources: [
                .copy("Resources/bootstrap-runtime.js"),
                .copy("Resources/bootstrap-widget.js"),
            ]),
        // iOS: jsr nodes -> UIKit (UIStackView/UILabel/UIButton/UIScrollView).
        // Sources compile to nothing on macOS (#if canImport(UIKit) && os(iOS)).
        .target(name: "JSRUIKit", dependencies: ["JSRCore"]),
        // macOS: jsr nodes -> AppKit (NSStackView/NSTextField/NSButton/NSScrollView)
        .target(name: "JSRAppKit", dependencies: ["JSRCore"]),
        // macOS demo: fixture picker + `--conformance <fixtures> --out <dir>` (P2)
        .executableTarget(name: "JSRAppKitDemo", dependencies: ["JSRAppKit"]),
        .testTarget(name: "JSRCoreTests", dependencies: ["JSRCore"]),
        .testTarget(name: "JSRAppKitTests", dependencies: ["JSRAppKit"]),
        .testTarget(name: "JSRUIKitTests", dependencies: ["JSRUIKit"]),
    ]
)
