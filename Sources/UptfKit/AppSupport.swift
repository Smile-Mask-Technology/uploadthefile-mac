public import Foundation

/// Locations of the small files the app keeps on disk.
public enum AppSupport {
    /// Environment variable that relocates the data directory (tests, sandboxes).
    public static let environmentKey = "UPTF_HOME"

    /// `~/Library/Application Support/UploadTheFile/` (created on demand, mode 0700).
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let dir: URL
        if let override = environment[environmentKey], !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            dir = base.appendingPathComponent("UploadTheFile", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}
