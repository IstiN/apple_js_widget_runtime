# Conformance — apple_js_widget_runtime (macOS host)

The contract and fixtures live in the pinned `IstiN/js_widget_runtime`
(`conformance.lock`); `bash scripts/fetch-conformance.sh` fetches them into
`.conformance/`.

## Host run (tree-level driver, JSRCoreTests)

```bash
source "$ROOT/env.sh"; cd "$ROOT/apple_js_widget_runtime/.worktrees/issue-1"
swift test --filter ConformanceSeeds
```

Writes one `result.json` per fixture (`platform: "macos"` when run through the
demo; the tree-level test run uses the same field set) into
`$JSR_CONFORMANCE_OUT` (default `/tmp/apple-host`).

## Demo run (AppKit views)

```bash
swift build --product JSRAppKitDemo
.build/debug/JSRAppKitDemo --conformance .conformance/js_widget_runtime/docs/conformance/fixtures --out /tmp/apple-macos
```

One `result.json` per seed (`hello`, `counter`, `scroll_list`) plus
`report.md`; `platform: "macos"`; final dump read live from the mapped views.
Menu mode (`swift run JSRAppKitDemo`, fixtures via the `JSR_FIXTURES` env var)
loads the same fixtures into a window. `swift run` is sandbox-blocked on the
lane Mac — run the built binary directly.

## Harness compare (the PASS verdicts)

```bash
node .conformance/js_widget_runtime/harness/harness.mjs compare \
  --fixtures .conformance/js_widget_runtime/docs/conformance/fixtures \
  --results /tmp/apple-macos \
  --out-report /tmp/apple-macos-report.md
```

Comparator semantics: `IstiN/js_widget_runtime` `docs/harness.md`. Expected
current state: `hello` PASS, `counter` PASS, `scroll_list` PASS (the AppKit
container renders its children, so the flutter#11 reference defect does not
apply on macOS).

## CI

`.github/workflows/quality.yml`, job `macos` (macos-15): pins fetch, bootstrap
drift check, `swift test --enable-code-coverage`, LCOV export, crap4swift gate
(threshold 8.0), demo run, harness compare; artifact `conformance-macos`.
Node 22 for the harness.

## iOS (CI only — the lane Mac has no Xcode/iOS SDK)

The iOS leg runs in the `ios` job of the same workflow (macos-15 runner):

1. `brew install xcodegen` and `xcodegen generate --spec Demo/iOS/project.yml`
   (the spec builds the `JSRUIDemo` app + `JSRUIKitTests` from the SwiftPM
   package).
2. `xcodebuild test` on the simulator (`iPhone 16`, or the first available
   iPhone when the image lacks it — the job records the pick) with
   `-enableCodeCoverage YES -resultBundlePath Coverage.xcresult`. The
   `conformanceSeedsPassWithRealViews` test runs the seeds through the
   `UIKitMapper` + `UIKitInteractionDriver` in the application window and
   writes the `ios` `result.json` files into the app container (`tmp/jsr-ios`).
3. The job collects the results from `xcrun simctl get_app_container`, runs
   the harness compare (artifact `conformance-ios`), and gates crap4swift on
   `Sources/JSRCore Sources/JSRUIKit` with the iOS lcov (threshold 8.0).
   Coverage comes from continuous-mode profile counters: Xcode overrides any
   scheme `LLVM_PROFILE_FILE` and points the test host at its own
   `%c`-continuous profraw path under `DARWIN_USER_TEMP_DIR` (probe evidence,
   run 45727031194), so the counters survive the SIGKILL'd test host; the job
   merges those profraws (`llvm-profdata merge -sparse`) and exports one lcov
   per image (`llvm-cov export -format=lcov`: `JSRUIDemo.app/JSRUIDemo` and
   `JSRUIKitTests.xctest/JSRUIKitTests`; one call per binary). Package code
   is linked into both images with the counters split, so duplicate `SF:`
   records are kept and the crap4swift parser merges them by summing the
   execution counts per line. Xcode's own `xccov` collection is unusable for
   this gate (probe run 45723927053: SwiftPM package targets register an
   empty stub product, 0 files).

Locally on the lane Mac only the syntax is verifiable:
`xcrun swiftc -parse` over the UIKit/demo/test sources.
