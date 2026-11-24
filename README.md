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
