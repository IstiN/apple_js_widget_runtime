import Testing
import Foundation

// TEMPORARY verification (probe era): prints the coverage environment the
// test process sees and persists it into the app container tmp, where the
// coverage step reads it. Removed once the probe confirms the scheme env
// reaches the process.
@Suite struct CoverageDiagTests {
    @Test func printProfileEnvironment() throws {
        let env = ProcessInfo.processInfo.environment
        var diag = ""
        diag += "LLVM_PROFILE_FILE=\(env["LLVM_PROFILE_FILE"] ?? "<unset>")\n"
        diag += "TMPDIR=\(env["TMPDIR"] ?? "<unset>")\n"
        try? diag.write(toFile: NSTemporaryDirectory() + "jsr-cov-diag.txt",
                        atomically: true, encoding: .utf8)
    }
}
