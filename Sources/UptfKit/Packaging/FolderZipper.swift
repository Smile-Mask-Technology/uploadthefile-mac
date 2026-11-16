public import Foundation

/// What `FolderZipper` leaves out. One implementation of the rules, used both for the preview
/// list and for the zip, so they cannot disagree.
public enum ZipExclusions {
    /// Directories that are never included, wherever they are in the tree.
    static let directoryNames: Set<String> = [".git", ".svn", ".hg", "node_modules", ".ssh"]

    /// Names (case-insensitive globs) that are never included, files or folders.
    static let namePatterns: [String] = [
        ".DS_Store", ".env", ".env.*", "*.pem", "*.key", "*.p12", "id_rsa*", "id_ed25519*", "*.keychain*",
    ]

    /// True when `name` looks like a secret or credential file (`.env`, `*.pem`, `id_rsa`, ...).
    public static func isSecretName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return namePatterns.contains { fnmatch($0.lowercased(), lowered, 0) == 0 }
    }

    /// Whether an entry with this last path component is skipped.
    static func excludes(name: String, isDirectory: Bool, includeHidden: Bool) -> Bool {
        if !includeHidden && name.hasPrefix(".") { return true }
        if isDirectory && directoryNames.contains(name) { return true }
        if name.contains("\n") || name.contains("\r") { return true }  // cannot be passed to zip line by line
        return isSecretName(name)
    }
}

/// Zips a folder with `/usr/bin/zip`, leaving out version control, dependencies, secrets and
/// hidden files.
public enum FolderZipper {
    public struct Output: Sendable, Equatable {
        /// The finished archive in a temporary directory. Delete `url.deletingLastPathComponent()` when done.
        public var url: URL
        /// Relative paths inside the archive, same as ``previewEntries(folder:includeHidden:)``.
        public var entries: [String]
        public var bytes: Int64
    }

    /// Relative paths (sorted, `/`-separated) of the regular files that will be included.
    /// Symbolic links are never followed or included.
    public static func previewEntries(folder: URL, includeHidden: Bool = false) throws -> [String] {
        let root = folder.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UptfError.unexpected("\(folder.path) is not a folder.")
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.producesRelativePathURLs])
        else {
            throw UptfError.unexpected("Can't read the folder \(folder.path).")
        }
        var entries: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { continue }
            let isDir = values.isDirectory == true
            if ZipExclusions.excludes(name: url.lastPathComponent, isDirectory: isDir, includeHidden: includeHidden) {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            if values.isRegularFile == true { entries.append(url.relativePath) }
        }
        return entries.sorted()
    }

    /// Zips `folder` into a temporary `<folder name>.zip`.
    public static func zip(folder: URL, includeHidden: Bool = false) async throws -> Output {
        let entries = try previewEntries(folder: folder, includeHidden: includeHidden)
        guard !entries.isEmpty else {
            throw UptfError.unexpected("There is nothing to put online in \(folder.lastPathComponent): every file is left out, or the folder is empty.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uptf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = folder.standardizedFileURL.lastPathComponent
        let archive = directory.appendingPathComponent(name.isEmpty ? "site.zip" : name + ".zip")

        do {
            try await runZip(in: folder.standardizedFileURL, archive: archive, entries: entries)
            let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return Output(url: archive, entries: entries, bytes: Int64(size))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func runZip(in folder: URL, archive: URL, entries: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -q quiet, -X no extra file attributes, -@ read names from stdin.
        process.arguments = ["-q", "-X", "-@", archive.path]
        process.currentDirectoryURL = folder
        let stdin = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        let list = Data((entries.joined(separator: "\n") + "\n").utf8)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: UptfError.unexpected("Couldn't get the folder ready: \(error.localizedDescription)"))
                return
            }
            // Feed the list off the calling thread: the pipe buffer is small.
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: list)
                try? stdin.fileHandleForWriting.close()
            }
        }
        guard status == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UptfError.unexpected("Couldn't get the folder ready (error \(status))" + (message.isEmpty ? "." : ": \(message)"))
        }
    }
}

/// Refuses to publish places that hold credentials.
public enum SensitivePath {
    /// Folders (relative to the home directory) that must never be published.
    static let protectedFolders = [".ssh", "Library/Keychains", ".gnupg", ".aws"]

    /// A human-readable reason when `url` is, is inside, or (for folders) contains a protected
    /// location, or is a secret-looking file such as `id_rsa` or `.env`. Nil when it is fine.
    public static func reason(
        for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let homeComponents = home.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for folder in protectedFolders {
            let protected = homeComponents + folder.split(separator: "/").map(String.init)
            let inside = target.count >= protected.count && Array(target.prefix(protected.count)) == protected
            let contains = protected.count > target.count && Array(protected.prefix(target.count)) == target
            if inside { return "it is inside ~/\(folder), which holds your passwords and keys" }
            if contains { return "it contains ~/\(folder), which holds your passwords and keys" }
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !(exists && isDirectory.boolValue), ZipExclusions.isSecretName(url.lastPathComponent) {
            return "“\(url.lastPathComponent)” looks like it holds a password or key"
        }
        return nil
    }
}
