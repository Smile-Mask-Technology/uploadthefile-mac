import AppKit
import ArgumentParser
import Foundation
import UptfKit

// MARK: - Output

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func note(_ message: String) {
    printError(message)
}

/// Runs a command body: prints `uptf: <message>` to stderr and exits non-zero on failure.
func runCommand(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let exit as ExitCode {
        throw exit
    } catch let error as CleanExit {
        throw error
    } catch is CancellationError {
        throw ExitCode(130)
    } catch let error as ValidationError {
        printError("uptf: \(error.message)")
        throw ExitCode(2)
    } catch let error as UptfError {
        printError("uptf: \(error.localizedDescription)")
        throw ExitCode(error.exitCode)
    } catch {
        printError("uptf: \(error.localizedDescription)")
        throw ExitCode.failure
    }
}

extension UptfError {
    /// 1 = general failure, 3 = not signed in, 4 = refused by the server (plan/scope/limits),
    /// 5 = rate limited (try again later).
    var exitCode: Int32 {
        switch self {
        case .notSignedIn: return 3
        case .server(let status, _) where status == 403: return 4
        case .rateLimited: return 5
        default: return 1
        }
    }
}

// MARK: - Environment

struct CLIContext {
    let config: UptfConfig
    let store: any TokenStore
    /// One client per command, so everything the command reads shares one page cache.
    let client: UptfClient
    let index: PublishedIndex

    init() throws {
        config = try UptfConfig.fromEnvironment()
        store = KeychainTokenStore()
        client = UptfClient(config: config, store: store)
        index = try PublishedIndex(config: config)
    }

    func authenticator(openURL: @escaping @Sendable (URL) -> Bool = BrowserOpener.open) throws -> Authenticator {
        Authenticator(config: config, store: store, registrations: try .standard(), openURL: openURL)
    }

    var publisher: Publisher {
        Publisher(client: client, index: index)
    }
}

// MARK: - Resolving <path-or-name>

struct Target {
    /// The page's current name (or id) on the server, for messages.
    var slug: String
    /// What API paths use: the page's id when the target came from a local path, otherwise the
    /// name or id the person typed. An id never changes, a name can move to another page.
    var pageRef: String
    /// The local record, when the page was published from this Mac.
    var entry: PublishedEntry?
}

func expandPath(_ string: String) -> URL {
    URL(fileURLWithPath: (string as NSString).expandingTildeInPath).standardizedFileURL
}

/// A local path that was put online from here → its link, found by id (so a rename made on the
/// website is followed; that costs one list read); anything else is taken as the link's name.
func resolve(_ reference: String, context: CLIContext) async throws -> Target {
    let url = expandPath(reference)
    let looksLikePath = reference.contains("/") || reference.hasPrefix(".") || reference.hasPrefix("~")
    if FileManager.default.fileExists(atPath: url.path) {
        if let entry = try await context.index.entry(for: url) {
            guard let page = try await context.publisher.livePage(for: entry) else {
                throw UptfError.unexpected("\(reference) went online at \(entry.url), but that link isn't in your account anymore. Run `uptf publish \(reference)` to get a new one.")
            }
            return Target(slug: page.slug, pageRef: page.id, entry: entry)
        }
        if looksLikePath {
            throw UptfError.unexpected("\(reference) isn't online from this Mac yet. Run `uptf publish \(reference)` first, or use the link's name.")
        }
    } else if looksLikePath {
        throw UptfError.unexpected("No such file or folder: \(reference)")
    }
    return Target(slug: reference, pageRef: reference, entry: try await context.index.entry(matching: reference))
}

// MARK: - Interaction

var standardInputIsTerminal: Bool { isatty(STDIN_FILENO) != 0 }

/// Asks a yes/no question on stderr. Without a terminal the answer is no.
func confirm(_ question: String) -> Bool {
    guard standardInputIsTerminal else { return false }
    FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return answer == "y" || answer == "yes"
}

/// Reads a line from the controlling terminal with echo off. Never from arguments or stdin.
func readSecret(prompt: String) throws -> String {
    let fd = open("/dev/tty", O_RDWR)
    guard fd >= 0 else {
        throw UptfError.unexpected("No terminal to read the password from. Run this command in a terminal.")
    }
    defer { close(fd) }
    _ = prompt.withCString { write(fd, $0, strlen($0)) }

    var original = termios()
    guard tcgetattr(fd, &original) == 0 else { throw UptfError.unexpected("Could not read terminal settings.") }
    var silent = original
    silent.c_lflag &= ~tcflag_t(ECHO)
    tcsetattr(fd, TCSAFLUSH, &silent)
    defer {
        tcsetattr(fd, TCSAFLUSH, &original)
        _ = write(fd, "\n", 1)
    }

    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1, byte != UInt8(ascii: "\n"), byte != UInt8(ascii: "\r") {
        bytes.append(byte)
    }
    return String(decoding: bytes, as: UTF8.self)
}

func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// MARK: - Formatting

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatDate(_ date: Date?) -> String {
    guard let date else { return "never" }
    return date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
}

/// When a link stays online until, in words: a date, or "you delete it".
func onlineUntil(_ date: Date?) -> String {
    date == nil ? "you delete it" : formatDate(date)
}

/// The plain words for a how-it-opens setting (the command takes the raw value).
func describeDisplay(_ raw: String) -> String {
    switch raw {
    case "preview": return "it opens right in the browser"
    case "preview_download": return "it opens in the browser, with a download button"
    case "download": return "download button only"
    default: return raw
    }
}

func pad(_ string: String, _ width: Int) -> String {
    string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
}

func jsonString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
