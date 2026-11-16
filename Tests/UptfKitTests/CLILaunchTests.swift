import Foundation
import Testing

/// Runs the built `uptf` binary. The unit tests cover UptfKit, but nothing else proves the
/// executable actually starts: a synchronous `Uptf.main()` compiles cleanly and then refuses to
/// run every command ("Asynchronous root command needs availability annotation").
@Suite("uptf launches")
struct CLILaunchTests {
    static let binary: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/uptf")

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("uptf-launch-\(UUID().uuidString)")
        var environment = ProcessInfo.processInfo.environment
        environment["UPTF_HOME"] = home.path
        environment["UPTF_SITE"] = "http://127.0.0.1:9"
        process.environment = environment
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: home) }
        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test func versionRuns() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "build uptf first")
        let result = try Self.run(["--version"])
        #expect(result.status == 0)
        #expect(!result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!result.stderr.contains("Asynchronous root command"))
    }

    @Test func anAsyncSubcommandRuns() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "build uptf first")
        // `status` is async and needs no network: signed out on a fresh home.
        let result = try Self.run(["status"])
        #expect(!result.stderr.contains("Asynchronous root command"))
        #expect(!result.stdout.contains("Asynchronous root command"))
        #expect(result.stdout.contains("Signed in: no"))
    }

    /// The help is read by people: the command is `delete`, and nothing says host or unpublish.
    @Test func helpUsesPlainWordsAndHasADeleteCommand() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.binary.path), "build uptf first")
        let result = try Self.run(["--help"])
        #expect(result.status == 0)
        #expect(result.stdout.contains("Publish a file or folder and get its link."))
        #expect(result.stdout.contains("Delete a file or folder you put online, and its link."))
        #expect(!result.stdout.contains("unpublish"))
        #expect(!result.stdout.lowercased().contains("host"))
        let delete = try Self.run(["delete", "--help"])
        #expect(delete.status == 0)
        #expect(delete.stdout.contains("Delete a file or folder you put online, and its link."))
    }
}
