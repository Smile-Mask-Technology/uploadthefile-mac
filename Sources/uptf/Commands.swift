import ArgumentParser
import Foundation
import UptfKit

// The command names (publish, update, delete ...) are the CLI's own. The words a
// person reads (help, messages, output labels) follow docs/voice.md: put online, link, stays online.

// MARK: - Account

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Sign in with your browser.")

    @Flag(help: "Print the sign-in link instead of opening the browser (for SSH or another browser).")
    var noBrowser = false

    mutating func run() async throws {
        let noBrowser = self.noBrowser
        let openURL: @Sendable (URL) -> Bool
        if noBrowser {
            openURL = { _ in true }
        } else {
            openURL = BrowserOpener.open
        }
        try await runCommand {
            let context = try CLIContext()
            let authenticator = try context.authenticator(openURL: openURL)
            if noBrowser {
                note("Open this link in a browser on this Mac to sign in to \(context.config.origin):")
            } else {
                note("Opening your browser to sign in to \(context.config.origin) …")
            }
            try await authenticator.signIn { url in
                note(noBrowser ? url.absoluteString : "If it doesn't open, visit:\n\(url.absoluteString)\n")
            }
            note("Signed in to \(context.config.origin).")
        }
    }
}

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Forget the saved sign-in on this Mac.")

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            if try await context.authenticator().signOut() {
                note("Signed out of \(context.config.origin).")
            } else {
                note("Signed out on this Mac. We couldn't reach Upload the File to finish signing out; you can remove \"Upload the File for Mac\" in your account settings.")
            }
        }
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show whether you are signed in.",
        discussion: "Exits with status 3 when not signed in.")

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let signedIn = try context.authenticator().isSignedIn()
            print("Site:      \(context.config.origin)")
            print("Signed in: \(signedIn ? "yes" : "no")")
            if !signedIn { throw ExitCode(3) }
        }
    }
}

// MARK: - Putting things online

struct Publish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Publish a file or folder and get its link.",
        discussion: """
            A folder is bundled first. Hidden files, files that hold passwords or keys, and developer \
            folders such as .git and node_modules are left out. A folder with an index.html at its top \
            level opens as a website.
            """)

    @Argument(help: "File or folder to put online.") var path: String
    @Option(help: "A name for your link (the first part of its address).") var name: String?
    @Flag(help: "Open a .zip (or a folder) as a website.") var site = false
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false
    @Flag(help: "Don't copy the link to the clipboard.") var noCopy = false
    @Flag(help: "Get a new link even if this path already has one.") var again = false
    @Flag(help: "Go ahead even if the path looks like it holds passwords or keys.") var force = false
    @Flag(help: "Include hidden files when sending a folder.") var includeHidden = false

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let publisher = context.publisher
            let url = expandPath(path)
            let plan = try publisher.prepare(url, allowSensitive: force, includeHidden: includeHidden)

            if !again, let existing = try await publisher.existingPublication(for: url) {
                throw UptfError.unexpected("Already online at \(existing.page.url). Run `uptf update \(path)` to replace it, or pass --again to get a separate link.")
            }
            if plan.kind == .folder {
                try confirmFolder(plan, assumeYes: yes, question: "Put these files online?")
            }
            let hostAsSite = site || (plan.kind == .folder && plan.hasRootIndexHtml)
            let outcome = try await publisher.publish(plan, name: name, hostAsSite: hostAsSite)
            report(outcome, copy: !noCopy)
        }
    }
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace a file or folder you put online and keep the same link.")

    @Argument(help: "File or folder you put online before.") var path: String
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false
    @Flag(help: "Don't copy the link to the clipboard.") var noCopy = false
    @Flag(help: "Include hidden files when sending a folder.") var includeHidden = false

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let publisher = context.publisher
            let url = expandPath(path)
            guard let entry = try await publisher.index.entry(for: url) else {
                throw UptfError.unexpected("\(path) isn't online from this Mac yet. Use `uptf publish \(path)`.")
            }
            let plan = try publisher.prepare(url, includeHidden: includeHidden)
            if plan.kind == .folder {
                try confirmFolder(plan, assumeYes: yes, question: "Replace \(entry.url) with these files?")
            }
            let outcome = try await publisher.update(plan, entry: entry)
            report(outcome, copy: !noCopy)
        }
    }
}

/// Shows exactly which files go online and asks first.
private func confirmFolder(_ plan: PublishPlan, assumeYes: Bool, question: String) throws {
    let limit = 200
    note("\(plan.url.lastPathComponent)/ — \(plan.entries.count) file\(plan.entries.count == 1 ? "" : "s") will go online:")
    for entry in plan.entries.prefix(limit) { note("  \(entry)") }
    if plan.entries.count > limit { note("  … and \(plan.entries.count - limit) more") }
    note("Left out: hidden files, files that hold passwords or keys, and developer folders such as .git and node_modules.")
    if plan.hasRootIndexHtml { note("This folder has an index.html, so it opens as a website.") }
    if assumeYes { return }
    guard standardInputIsTerminal else {
        throw UptfError.unexpected("Not a terminal, so I can't ask. Re-run with --yes to put the folder online.")
    }
    guard confirm(question) else { throw ExitCode.failure }
}

private func report(_ outcome: PublishOutcome, copy: Bool) {
    print(outcome.result.url)
    if copy {
        copyToClipboard(outcome.result.url)
        note("Link copied to the clipboard.")
    }
    if outcome.entry == nil {
        note("Warning: it's online, but this Mac couldn't remember it"
            + (outcome.historyError.map { " (\($0))." } ?? "."))
    }
}

// MARK: - Listing and inspecting

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the links you have.")

    @Flag(help: "Print JSON.") var json = false

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let pages = try await context.client.pages()
            // Keep local links in step with the website: follow renames, forget deleted links.
            // Only with a complete list, since a full one may have cut some off.
            if pages.count < UptfClient.listLimit { _ = try? await context.index.reconcile(with: pages) }
            if json {
                print(try jsonString(pages))
                return
            }
            if pages.isEmpty {
                note("No links yet.")
                return
            }
            let nameWidth = min(max(pages.map { $0.slug.count }.max() ?? 4, 4), 40)
            print("\(pad("NAME", nameWidth))  \(pad("KIND", 6))  \(pad("SIZE", 9))  \(pad("ONLINE UNTIL", 20))  LINK")
            for page in pages {
                print(
                    "\(pad(page.slug, nameWidth))  \(pad(page.kind, 6))  \(pad(formatBytes(page.sizeBytes), 9))  "
                        + "\(pad(onlineUntil(page.expiresAt), 20))  \(page.url)")
            }
        }
    }
}

struct Info: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the details and settings of a link.")

    @Argument(help: "A file or folder you put online, or the link's name.") var target: String
    @Flag(help: "Also read the password, email and how-it-opens settings (counts as 3 more requests).") var settings = false
    @Flag(help: "Print JSON.") var json = false

    private struct Output: Encodable {
        var details: PageDetails
        var localPath: String?
        var changedSincePublish: Bool?
    }

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let resolved = try await resolve(target, context: context)
            let details = try await context.client.details(resolved.slug, includeSettings: settings)
            try? await context.index.apply(details.page)

            var changed: Bool?
            if let entry = resolved.entry, let local = await context.index.currentURL(for: entry) {
                changed = try? await context.index.changedSincePublish(local)
            }
            let output = Output(details: details, localPath: resolved.entry?.lastKnownPath, changedSincePublish: changed)
            if json {
                print(try jsonString(output))
                return
            }
            let page = details.page
            print("Name:       \(page.slug)")
            print("Link:       \(page.url)")
            print("File:       \(page.fileName) (\(page.kind), \(formatBytes(page.sizeBytes)), \(page.fileCount) file\(page.fileCount == 1 ? "" : "s"))")
            print("Put online: \(formatDate(page.createdAt))")
            print("Online until: \(onlineUntil(page.expiresAt))")
            if let protected = details.passwordProtected { print("Password:   \(protected ? "protected" : "none")") }
            if let gate = details.emailGateEnabled { print("Ask for email first: \(gate ? "yes" : "no")") }
            if let mode = details.displayMode { print("How it opens: \(describeDisplay(mode.rawValue))") }
            if let path = output.localPath {
                print("On this Mac: \(path)" + (changed == true ? " (changed since you put it online)" : ""))
            }
        }
    }
}

// MARK: - Changing settings

struct Rename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Change a link's name. The old link stops working.")

    @Argument(help: "A file or folder you put online, or the link's name.") var target: String
    @Argument(help: "The new name (3–32 characters: a–z, 0–9, hyphens).") var newName: String
    @Flag(help: "Don't copy the new link to the clipboard.") var noCopy = false

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let resolved = try await resolve(target, context: context)
            let page = try await context.client.rename(resolved.slug, to: newName)
            // The link keeps its id, so the local record follows the new name.
            try? await context.index.apply(page)
            print(page.url)
            if !noCopy { copyToClipboard(page.url) }
        }
    }
}

struct Password: AsyncParsableCommand {
    enum Action: String, ExpressibleByArgument, CaseIterable { case set, remove }

    static let configuration = CommandConfiguration(
        abstract: "Protect a link with a password, or remove the password.",
        discussion: "The password is typed at a hidden prompt, never given on the command line.")

    @Argument(help: "A file or folder you put online, or the link's name.") var target: String
    @Argument(help: "set or remove.") var action: Action

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let resolved = try await resolve(target, context: context)
            let client = context.client
            switch action {
            case .set:
                let password = try readSecret(prompt: "New password (6–72 characters): ")
                guard (6...72).contains(password.count) else {
                    throw UptfError.unexpected("A password must be 6 to 72 characters long.")
                }
                guard try readSecret(prompt: "Repeat password: ") == password else {
                    throw UptfError.unexpected("The passwords don't match.")
                }
                try await client.setPassword(password, for: resolved.slug)
                note("Password set for \(resolved.slug).")
            case .remove:
                try await client.removePassword(for: resolved.slug)
                note("Password removed from \(resolved.slug).")
            }
        }
    }
}

struct Gate: AsyncParsableCommand {
    enum State: String, ExpressibleByArgument, CaseIterable { case on, off }

    static let configuration = CommandConfiguration(
        abstract: "Ask people for their email before they can open a link.")

    @Argument(help: "A file or folder you put online, or the link's name.") var target: String
    @Argument(help: "on or off.") var state: State
    @Option(help: "The message people see (up to 200 characters).") var message: String?

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let resolved = try await resolve(target, context: context)
            try await context.client.setEmailGate(resolved.slug, enabled: state == .on, message: message)
            note(state == .on
                ? "People will be asked for their email before they open \(resolved.slug)."
                : "People can open \(resolved.slug) without giving their email.")
        }
    }
}

struct Expiry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set how long a link stays online.",
        discussion: "Give a date and time like 2026-12-31T23:59:00Z, or `never` to keep it online until you delete it.")

    @Argument(help: "A file or folder you put online, or the link's name.") var target: String
    @Argument(help: "A date and time like 2026-12-31T23:59:00Z, or never.") var when: String

    mutating func run() async throws {
        try await runCommand {
            let date: Date?
            if when.lowercased() == "never" {
                date = nil
            } else if let parsed = parseDateTime(when) {
                date = parsed
            } else {
                throw ValidationError("“\(when)” isn't a date and time like 2026-12-31T23:59:00Z, or `never`.")
            }
            let context = try CLIContext()
            let resolved = try await resolve(target, context: context)
            try await context.client.setExpiry(resolved.slug, date)
            note(date == nil
                ? "\(resolved.slug) stays online until you delete it."
                : "\(resolved.slug) stays online until \(formatDate(date)).")
        }
    }
}

private func parseDateTime(_ string: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
    return try? Date.ISO8601FormatStyle().parse(string)
}

struct Display: AsyncParsableCommand {
    enum Mode: String, ExpressibleByArgument, CaseIterable {
        case preview
        case previewDownload = "preview_download"
        case download
    }

    static let configuration = CommandConfiguration(
        abstract: "Choose how a single-file link opens: in the browser, with a download button, or download only.")

    @Argument(help: "A file or folder you put online, or the link's name.") var target: String
    @Argument(help: "preview (opens in the browser), preview_download (with a download button) or download (download button only).") var mode: Mode

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let resolved = try await resolve(target, context: context)
            try await context.client.setDisplay(resolved.slug, mode: DisplayMode(rawValue: mode.rawValue) ?? .preview)
            note("\(resolved.slug): \(describeDisplay(mode.rawValue)).")
        }
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a file or folder you put online, and its link.")

    @Argument(help: "A file or folder you put online, or the link's name.") var target: String
    @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

    mutating func run() async throws {
        try await runCommand {
            let context = try CLIContext()
            let resolved = try await resolve(target, context: context)
            if !yes {
                guard standardInputIsTerminal else {
                    throw UptfError.unexpected("Not a terminal, so I can't ask. Re-run with --yes to delete \(resolved.slug).")
                }
                guard confirm("Delete \(resolved.slug) and its link for good? People who have the link can no longer open it.") else { throw ExitCode.failure }
            }
            try await context.client.unpublish(resolved.slug)
            if let entry = resolved.entry { try? await context.index.remove(id: entry.id) }
            note("Deleted \(resolved.slug).")
        }
    }
}
