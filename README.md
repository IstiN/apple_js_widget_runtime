# apple_js_widget_runtime

iOS + macOS renderer for jsr widgets as ONE Swift Package — the JSC core is
**100% shared**, only the view-mapping layer differs (UIKit vs AppKit).

| Target | Role |
|---|---|
| `JSRCore` | JavaScriptCore bridge, bootstrap, tree model, reconciler, conformance runner (AUI dump, event trace) — platform-free |
| `JSRUIKit` | jsr nodes → UIKit (iOS) |
| `JSRAppKit` | jsr nodes → AppKit (macOS) |

Family: contract + **testing protocol** [js_widget_runtime](https://github.com/IstiN/js_widget_runtime) · engine core [js_runtime](https://github.com/IstiN/js_runtime) · reference [flutter_js_widget_runtime](https://github.com/IstiN/flutter_js_widget_runtime) · Android [android_js_widget_runtime](https://github.com/IstiN/android_js_widget_runtime) · web [react_js_widget_runtime](https://github.com/IstiN/react_js_widget_runtime)

Engine: JavaScriptCore (system framework). QuickJS parity via js_runtime#2 adapter if conformance demands identical engine semantics.

## Key advantage

`JSContext` runs on macOS too → conformance fixtures execute on the Mac
directly (structure L0/L1 without any device), UIKit/AppKit mappers verified
by the same AUI dumps on simulator/host.

## Quality gate

The `Quality` workflow gates every push and PR (`macos` job on macos-15).
The same two commands locally (repo root, `$ROOT` = fleet root):

```bash
# coverage of the unit tests → LCOV (plan 1.7); per-binary export + dedupe
# (a combined two-binary export drops the second binary's records)
swift test --enable-code-coverage
xcrun llvm-profdata merge -sparse .build/debug/codecov/default.profdata -o Coverage.profdata
rm -f coverage.lcov
for BIN in JSRCoreTests JSRAppKitTests; do
  xcrun llvm-cov export -format=lcov -instr-profile Coverage.profdata \
    ".build/debug/$BIN.xctest/Contents/MacOS/$BIN"
done | awk 'BEGIN{keep=0} /^SF:/{keep=($0 ~ "^SF:.*/Sources/(JSRCore|JSRAppKit)/")} {if(keep)print}' \
  | awk '/^SF:/{p=$0; if(seen[p]){skip=1; next} seen[p]=1} {if(!skip)print} /^end_of_record/{skip=0}' \
  > coverage.lcov

# CRAP-4 gate, first-party sources only, threshold 8.0 (pinned crap4swift);
# macOS covers JSRCore+JSRAppKit — JSRUIKit is gated by the iOS job with the
# iOS lcov (no macOS coverage exists for iOS-only code)
bash scripts/fetch-conformance.sh
swift build -c release --package-path .conformance/crap4swift
.conformance/crap4swift/.build/release/crap4swift Sources/JSRCore Sources/JSRAppKit --coverage coverage.lcov --threshold 8.0
```

iOS (`Quality` job `ios` only — needs Xcode + the iOS SDK, not available on
the lane Mac): the job builds the `JSRUIDemo` demo project via XcodeGen
(`xcodegen generate --spec Demo/iOS/project.yml`), runs `JSRUIKitTests` on the
simulator with `-enableCodeCoverage YES`, converts the xcresult with
`scripts/xcresult-to-lcov.swift` and gates crap4swift on
`Sources/JSRCore Sources/JSRUIKit` with the iOS lcov file.

A missing or empty `coverage.lcov` fails the job. A function above 8.0 is
split or gets more unit tests — the threshold is never raised and no function
is excluded.
