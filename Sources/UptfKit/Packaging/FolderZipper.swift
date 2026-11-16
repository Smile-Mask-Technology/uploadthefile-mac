public import Foundation

/// What `FolderZipper` leaves out. One implementation of the rules, used both for the preview
/// list and for the zip, so they cannot disagree. Names are compared case-insensitively, because
/// the default macOS file system is.
public enum ZipExclusions {
    /// Directories (lowercase) that are never included, wherever they are in the tree. Hidden
    /// folders are normally left out anyway; these stay out even with `includeHidden`.
    static let directoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".azure",
    ]

    /// Names (case-insensitive globs) that are never included, files or folders.
    static let namePatterns: [String] = [
        ".DS_Store", ".env", ".env.*", ".envrc", ".netrc", ".npmrc", ".pgpass", ".htpasswd", ".git-credentials",
        "*.pem", "*.key", "*.p12", "*.pfx", "*.jks", "*.keystore", "*.ppk", "*.kdbx", "*.ovpn",
        "id_rsa*", "id_ed25519*", "id_ecdsa*", "id_dsa*", "*.keychain*",
        "*.tfstate*", "*.tfvars", "*.mobileprovision", "credentials.json", "service-account*.json",
    ]

    /// True when `name` looks like a secret or credential file (`.env`, `*.pem`, `id_rsa`, ...).
    public static func isSecretName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return namePatterns.contains { fnmatch($0.lowercased(), lowered, 0) == 0 }
    }

    /// Whether an entry with this last path component is skipped.
    static func excludes(name: String, isDirectory: Bool, includeHidden: Bool) -> Bool {
        if !includeHidden && name.hasPrefix(".") { return true }
        if isDirectory && directoryNames.contains(name.lowercased()) { return true }
        if name.contains("\n") || name.contains("\r") { return true }  // cannot be passed to zip line by line
        return isSecretName(name)
    }
}

/// How much a folder may hold before it is refused, and the other numbers the zipping relies on.
enum FolderLimits {
    static let megabyte: Int64 = 1024 * 1024
    /// Any folder: files, and bytes before zipping.
    static let maxFiles = 10_000
    static let maxBytes: Int64 = 500 * megabyte
    /// A folder with an `index.html` at its top level opens as a website, which has tighter limits.
    static let websiteMaxFiles = 500
    static let websiteMaxBytes: Int64 = 40 * megabyte
    static let websiteMaxFileBytes: Int64 = 20 * megabyte
    /// `zip` stops reading its list at a name of `PATH_MAX` (1024) bytes or more, without an error.
    static let maxPathBytes = 1000
    /// Longest base name of the archive file, leaving room for `.zip` inside the 255 byte limit.
    static let maxArchiveNameBytes = 200
    /// Seconds `zip` may run before it is stopped.
    static let zipTimeout: TimeInterval = 300

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}

/// Zips a folder with `/usr/bin/zip`, leaving out version control, dependencies, secrets and
/// hidden files.
public enum FolderZipper {
    public struct Output: Sendable, Equatable {
        /// The finished archive in a temporary directory. Delete `url.deletingLastPathComponent()` when done.
        public var url: URL
        /// Relative paths inside the archive: the entries that were asked for and still checked out.
        public var entries: [String]
        public var bytes: Int64
        /// Requested entries that were no longer regular files inside the folder when zipping started.
        public var skipped: [String] = []
    }

    /// Relative paths (sorted, `/`-separated) of the regular files that will be included.
    /// Symbolic links are never followed or included. Throws when the folder holds more than
    /// ``FolderLimits`` allows, without reading the rest of it.
    public static func previewEntries(folder: URL, includeHidden: Bool = false) throws -> [String] {
        try previewEntries(folder: folder, includeHidden: includeHidden, maxPathBytes: FolderLimits.maxPathBytes)
    }

    static func previewEntries(folder: URL, includeHidden: Bool, maxPathBytes: Int) throws -> [String] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UptfError.unexpected("\(folder.path) is not a folder.")
        }
        let isWebsite = regularFileSize(atPath: root.appendingPathComponent("index.html").path) != nil
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.producesRelativePathURLs])
        else {
            throw UptfError.unexpected("Can't read the folder \(folder.path).")
        }
        var entries: [String] = []
        var totalBytes: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { continue }
            let isDir = values.isDirectory == true
            if ZipExclusions.excludes(name: url.lastPathComponent, isDirectory: isDir, includeHidden: includeHidden) {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let path = url.relativePath
            guard path.utf8.count <= maxPathBytes else {
                throw UptfError.unexpected(
                    "The path of “\(url.lastPathComponent)” is too long to put online. Rename it or move it closer to the top of the folder.")
            }
            let size = Int64(values.fileSize ?? 0)
            entries.append(path)
            totalBytes += size
            try checkLimits(
                files: entries.count, bytes: totalBytes, fileName: url.lastPathComponent, fileBytes: size, isWebsite: isWebsite)
        }
        return entries.sorted()
    }

    private static func checkLimits(files: Int, bytes: Int64, fileName: String, fileBytes: Int64, isWebsite: Bool) throws {
        if isWebsite {
            if files > FolderLimits.websiteMaxFiles {
                throw UptfError.unexpected(
                    "This folder has an index.html, so it opens as a website, and a website can have up to \(FolderLimits.websiteMaxFiles.formatted()) files. This folder has more. Choose a smaller folder.")
            }
            if fileBytes > FolderLimits.websiteMaxFileBytes {
                throw UptfError.unexpected(
                    "“\(fileName)” is \(FolderLimits.size(fileBytes)). This folder has an index.html, so it opens as a website, and a website can have files up to \(FolderLimits.size(FolderLimits.websiteMaxFileBytes)) each.")
            }
            if bytes > FolderLimits.websiteMaxBytes {
                throw UptfError.unexpected(
                    "This folder has an index.html, so it opens as a website, and a website can hold up to \(FolderLimits.size(FolderLimits.websiteMaxBytes)). This folder has more. Choose a smaller folder.")
            }
            return
        }
        if files > FolderLimits.maxFiles {
            throw UptfError.unexpected(
                "This folder has more than \(FolderLimits.maxFiles.formatted()) files, which is too many to put online. Choose a smaller folder.")
        }
        if bytes > FolderLimits.maxBytes {
            throw UptfError.unexpected(
                "This folder holds more than \(FolderLimits.size(FolderLimits.maxBytes)), which is too much to put online. Choose a smaller folder.")
        }
    }

    /// Zips `folder` into a temporary `<folder name>.zip`, with the files `includeHidden` selects now.
    /// Use ``zip(folder:entries:)`` to zip a list that was shown to the user.
    public static func zip(folder: URL, includeHidden: Bool = false) async throws -> Output {
        try await zip(folder: folder, entries: previewEntries(folder: folder, includeHidden: includeHidden))
    }

    /// Zips exactly `entries` (paths relative to `folder`) into a temporary `<folder name>.zip`. The
    /// folder is not listed again; an entry that is no longer a regular file inside the folder (for
    /// example one swapped for a link to somewhere else) is left out and reported in `skipped`.
    public static func zip(folder: URL, entries requested: [String]) async throws -> Output {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let (entries, skipped, bytes) = verify(requested, in: root)
        guard !entries.isEmpty else {
            throw UptfError.unexpected("There is nothing to put online in \(folder.lastPathComponent): every file is left out, or the folder is empty.")
        }
        guard bytes <= UptfClient.maxUploadBytes else {
            throw UptfError.unexpected(
                "This folder holds \(FolderLimits.size(bytes)), and the app can send up to \(FolderLimits.size(UptfClient.maxUploadBytes)). Choose a smaller folder.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("uptf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent(archiveName(for: root.lastPathComponent))

        do {
            // `./` keeps a file named `-` from meaning "standard input"; zip drops it from the stored name.
            let list = directory.appendingPathComponent("names.txt")
            try Data((entries.map { "./" + $0 }.joined(separator: "\n") + "\n").utf8).write(to: list)
            // -q quiet, -X no extra file attributes, -y store links as links, -nw no wildcard matching
            // of names, -@ read names from standard input. The archive path is absolute.
            let result = try await run(
                executable: URL(fileURLWithPath: "/usr/bin/zip"),
                arguments: ["-q", "-X", "-y", "-nw", "-@", archive.path],
                directory: root, input: list,
                errorFile: directory.appendingPathComponent("errors.txt"), timeout: FolderLimits.zipTimeout)
            guard result.status == 0 else {
                let message = result.errorText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UptfError.unexpected("Couldn't get the folder ready (error \(result.status))" + (message.isEmpty ? "." : ": \(message)"))
            }
            let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return Output(url: archive, entries: entries, bytes: Int64(size), skipped: skipped)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// The archive's file name: the folder name, cut so that `.zip` still fits in a file name.
    static func archiveName(for folderName: String) -> String {
        guard !folderName.isEmpty, folderName != "/" else { return "site.zip" }
        var name = folderName
        while name.utf8.count > FolderLimits.maxArchiveNameBytes { name.removeLast() }
        return name + ".zip"
    }

    /// Splits `entries` into those that are still regular files inside `root` (with their total
    /// size) and those that are not: gone, replaced by a link or another kind of file, outside the
    /// folder, or not a plain relative path.
    private static func verify(_ entries: [String], in root: URL) -> (kept: [String], skipped: [String], bytes: Int64) {
        guard let realRoot = realPath(root.path) else { return ([], entries, 0) }
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        var kept: [String] = []
        var skipped: [String] = []
        var bytes: Int64 = 0
        for entry in entries {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            let plain = !entry.isEmpty && !entry.hasPrefix("/") && !entry.contains("\n")
                && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            let full = prefix + entry
            guard plain, let resolved = realPath(full), resolved.hasPrefix(prefix),
                let size = regularFileSize(atPath: full)
            else {
                skipped.append(entry)
                continue
            }
            kept.append(entry)
            bytes += size
        }
        return (kept, skipped, bytes)
    }

    /// The size of the file at `path` if it is a regular file itself (not a link to one), else nil.
    private static func regularFileSize(atPath path: String) -> Int64? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    struct ProcessResult: Sendable {
        var status: Int32
        /// The start of what the process wrote to standard error.
        var errorText: String
    }

    /// Runs `executable` with `input` as its standard input, and standard error going to a file, so
    /// no pipe can fill up and stop it. Terminates the process after `timeout` seconds, or when the
    /// calling task is cancelled.
    static func run(
        executable: URL, arguments: [String], directory: URL, input: URL, errorFile: URL, timeout: TimeInterval
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // zip reads extra options from these.
        var environment = ProcessInfo.processInfo.environment
        environment["ZIPOPT"] = nil
        environment["ZIP"] = nil
        process.environment = environment

        guard FileManager.default.createFile(atPath: errorFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw UptfError.unexpected("Couldn't get the folder ready.")
        }
        let stdin: FileHandle
        let stderr: FileHandle
        do {
            stdin = try FileHandle(forReadingFrom: input)
            stderr = try FileHandle(forWritingTo: errorFile)
        } catch {
            throw UptfError.unexpected("Couldn't get the folder ready: \(error.localizedDescription)")
        }
        defer {
            try? stdin.close()
            try? stderr.close()
        }
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        let running = RunningProcess(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    running.markFinished()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try running.start(timeout: timeout)
                } catch is CancellationError {
                    continuation.resume(throwing: CancellationError())
                } catch {
                    continuation.resume(throwing: UptfError.unexpected("Couldn't get the folder ready: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            running.cancel()
        }
        if running.wasCancelled { throw CancellationError() }
        if running.didTimeOut {
            throw UptfError.unexpected("Getting the folder ready took too long, so it was stopped. Try a smaller folder.")
        }
        let text = (try? Data(contentsOf: errorFile).prefix(4000)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return ProcessResult(status: status, errorText: text)
    }
}

/// A started `Process` that can be stopped from another thread: by the task being cancelled, or by the timeout.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var running = false
    private var cancelled = false
    private var timedOut = false

    init(_ process: Process) { self.process = process }

    var wasCancelled: Bool { lock.withLock { cancelled } }
    var didTimeOut: Bool { lock.withLock { timedOut } }

    func start(timeout: TimeInterval) throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
            running = true
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            lock.withLock {
                guard running, process.isRunning else { return }
                timedOut = true
                process.terminate()
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if running, process.isRunning { process.terminate() }
        }
    }

    func markFinished() {
        lock.withLock { running = false }
    }
}

/// Places that must not be published: ones that are, or sit inside, a folder that holds
/// credentials (a warning the person can confirm), and ones that contain such a folder, so the
/// whole of them can't be published at all.
public enum SensitivePath {
    /// Paths (relative to the home directory) that hold passwords, keys or private data.
    static let protectedPaths = [
        ".ssh", ".gnupg", ".aws", ".kube", ".azure", ".config/gh", ".config/gcloud", ".docker/config.json",
        ".netrc", ".npmrc", ".pgpass", ".git-credentials",
        "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Cookies", "Library/Safari",
        "Library/Application Support/Google/Chrome", "Library/Application Support/Firefox",
        "Library/Application Support/BraveSoftware", "Library/Application Support/Microsoft Edge",
        "Library/Application Support/Arc", "Library/Application Support/com.apple.sharedfilelist",
        "Library/Application Support/UploadTheFile",
    ]

    /// What a person reads when a folder is refused because it holds a protected folder.
    public static let containsProtectedMessage =
        "This folder holds private files (like your passwords and keys), so it can't be put online. Choose a smaller folder."

    /// Path components, lowercased: the default file system does not tell `.SSH` from `.ssh`.
    private static func components(of url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
    }

    private static func components(of relative: String, below home: [String]) -> [String] {
        home + relative.split(separator: "/").map { String($0).lowercased() }
    }

    /// True when `url` is a place that holds a protected folder: the home folder or anything above
    /// it (`/`, `/Users`), a disk or other volume, `~/Library`, or any folder on the way to
    /// one of ``protectedPaths``. Such a folder is refused whatever else is allowed.
    public static func containsProtectedFolder(
        _ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let target = components(of: url)
        if target.count <= 1 { return true }  // "/"
        if target.count <= 3, target[1] == "volumes" { return true }  // "/Volumes", "/Volumes/<disk>"
        let homeComponents = components(of: home)
        return protectedPaths.contains { path in
            let protected = components(of: path, below: homeComponents)
            return protected.count > target.count && Array(protected.prefix(target.count)) == target
        }
    }

    /// A human-readable reason when `url` is or is inside a protected location, or is a
    /// secret-looking file such as `id_rsa` or `.env`. Nil when it is fine. Places that
    /// contain a protected folder are not covered here: see ``containsProtectedFolder(_:home:)``.
    public static func reason(
        for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let target = components(of: url)
        let homeComponents = components(of: home)
        for path in protectedPaths {
            let protected = components(of: path, below: homeComponents)
            guard target.count >= protected.count, Array(target.prefix(protected.count)) == protected else { continue }
            let place = target.count == protected.count ? "it is" : "it is inside"
            return "\(place) ~/\(path), which holds your passwords and keys"
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !(exists && isDirectory.boolValue) {
            // A link is judged by its own name and by the name of what it points to.
            let names = [url.lastPathComponent, url.standardizedFileURL.resolvingSymlinksInPath().lastPathComponent]
            if let name = names.first(where: ZipExclusions.isSecretName) {
                return "“\(name)” looks like it holds a password or key"
            }
        }
        return nil
    }
}
