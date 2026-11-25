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
