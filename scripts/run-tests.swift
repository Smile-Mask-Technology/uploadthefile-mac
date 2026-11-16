// Runs the package's Swift Testing tests when only the Command Line Tools are installed.
//
// With the Command Line Tools alone, `swift test` builds the test bundle but runs nothing and
// exits 0, even when a test fails. This driver loads the built bundle (its tests register
// themselves through the bundle's __swift5_tests section) and calls Swift Testing's own SwiftPM
// entry point, so the output and the exit code are the real ones. scripts/test.sh compiles it.
// With Xcode installed, or in CI, plain `swift test` is enough.
import Foundation
import Testing

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: run-tests <path to the test bundle executable>\n".utf8))
    exit(64)
}
guard dlopen(arguments[1], RTLD_NOW | RTLD_GLOBAL) != nil else {
    let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
    FileHandle.standardError.write(Data("could not load the test bundle: \(reason)\n".utf8))
    exit(70)
}
let status: CInt = await Testing.__swiftPMEntryPoint(passing: nil)
exit(status)
