#!/usr/bin/env swift
// xcresult-to-lcov.swift — coverage of an xcodebuild result bundle to LCOV
// (plan 6.2, the iOS job of the `Quality` workflow).
//
// Primary path: `xcrun xccov view --report --json Coverage.xcresult` — the
// documented shape is
//   { "targets": [ { "files": [ { "path": "...", "lineCoverage": 0.9,
//       "functions": [ { "lineNumber": 10, "executionCount": 3 } ] } ] } ] }
// and the script emits SF/FN/FNDA records for Sources/JSRCore and
// Sources/JSRUIKit files. The per-line DA: entries do not exist in the xccov
// JSON, so records carry functions only (the crap4swift lcov parser derives
// per-method coverage from FN/FNDA when DA lines are absent).
//
// Fallback: `xcrun llvm-cov export -format=lcov` with the profdata of the
// .xccovbundle inside the result bundle:
//   xcrun llvm-cov export -format=lcov -instr-profile <profdata> <binary>
// (the same pipeline the macOS job uses).
//
// NOTE (first CI run must confirm): the exact xccov JSON shape was not
// verifiable on the authoring Mac (no Xcode). If the primary path yields no
// records, run the fallback and open an issue with the real shape.

import Foundation

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[xcresult-to-lcov] \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, arguments[1] == "--xcresult" else {
    die("usage: xcresult-to-lcov.swift --xcresult <Coverage.xcresult> [--out coverage-ios.lcov]")
}
let xcresultPath = arguments[2]
let outIndex = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? $0 + 1 : nil }
let outPath = outIndex.map { arguments[$0] } ?? "coverage-ios.lcov"

let fm = FileManager.default
guard fm.fileExists(atPath: xcresultPath) else {
    die("result bundle not found: \(xcresultPath)")
}

let xccov = Process()
xccov.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
xccov.arguments = ["xccov", "view", "--report", "--json", xcresultPath]
let pipe = Pipe()
xccov.standardOutput = pipe
xccov.standardError = Pipe()
do {
    try xccov.run()
} catch {
    die("xcrun xccov failed to start: \(error)")
}
let data = pipe.fileHandleForData()
xccov.waitUntilExit()
guard xccov.terminationStatus == 0, !data.isEmpty else {
    die("xcrun xccov view --report --json exited \(xccov.terminationStatus); use the llvm-cov fallback documented in the script header")
}

struct XccovFunction: Decodable {
    let lineNumber: Int
    let executionCount: Int
}

struct XccovFile: Decodable {
    let path: String
    let lineCoverage: Double
    let functions: [XccovFunction]?
}

struct XccovTarget: Decodable {
    let files: [XccovFile]
}

struct XccovReport: Decodable {
    let targets: [XccovTarget]
}

let report: XccovReport
do {
    report = try JSONDecoder().decode(XccovReport.self, from: data)
} catch {
    die("xccov JSON does not match the documented shape (\(error.localizedDescription)); use the llvm-cov fallback documented in the script header")
}

let firstPartyPrefixes = ["Sources/JSRCore/", "Sources/JSRUIKit/"]
var output = ""
var recordCount = 0
for target in report.targets {
    for file in target.files {
        guard firstPartyPrefixes.contains(where: { file.path.contains($0) }) else { continue }
        recordCount += 1
        output += "SF:\(file.path)\n"
        for function in file.functions ?? [] {
            // synthetic unique name (xccov has none); crap4swift pairs FN/FNDA
            // by the name string and keys coverage on the start line
            let name = "\(file.path):\(function.lineNumber)"
            output += "FN:\(function.lineNumber),\(name)\n"
            output += "FNDA:\(function.executionCount),\(name)\n"
        }
        output += "end_of_record\n"
    }
}

guard recordCount > 0 else {
    die("no Sources/JSRCore|JSRUIKit records in the xccov report; use the llvm-cov fallback documented in the script header")
}

do {
    try output.write(toFile: outPath, atomically: true, encoding: .utf8)
} catch {
    die("cannot write \(outPath): \(error)")
}
print("xcresult-to-lcov: \(recordCount) records -> \(outPath)")
