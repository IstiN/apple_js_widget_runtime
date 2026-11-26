import Testing
import Foundation

// TEMPORARY diagnostic (probe era): prints the coverage environment the test
// process sees and persists it into the app container tmp, where the workflow
// diagnostic step reads it. Removed before the final push.
@Suite struct CoverageDiagTests {
    @Test func printProfileEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        var diag = ""
        diag += "LLVM_PROFILE_FILE=\(env["LLVM_PROFILE_FILE"] ?? "<unset>")\n"
        diag += "TMPDIR=\(env["TMPDIR"] ?? "<unset>")\n"
        diag += "TEMP_DIR=\(env["TEMP_DIR"] ?? "<unset>")\n"
        diag += "CWD=\(FileManager.default.currentDirectoryPath)\n"
        diag += "NSTemporaryDirectory=\(NSTemporaryDirectory())\n"
        print("DIAG-BEGIN\n\(diag)DIAG-END")
        try? diag.write(toFile: NSTemporaryDirectory() + "jsr-cov-diag.txt",
                        atomically: true, encoding: .utf8)
    }
}
