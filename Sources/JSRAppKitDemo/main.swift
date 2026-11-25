import JSRAppKit

// Thin executable: parse arguments, dispatch to the JSRAppKit demo entry
// points (the CRAP gate scans Sources/; this file declares no functions).
let mode = jsrAppKitDemo.parseArguments(CommandLine.arguments)
switch mode {
case .conformance(let fixtures, let out):
    jsrAppKitDemo.runConformanceHeadless(fixtures: fixtures, out: out)
case .menu(let fixtures):
    jsrAppKitDemo.runMenu(fixturesRoot: fixtures)
}
