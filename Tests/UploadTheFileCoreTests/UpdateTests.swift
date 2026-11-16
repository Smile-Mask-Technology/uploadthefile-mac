import Foundation
import Testing

/// Automatic updates (Sparkle): the Info.plist keys, the appcast writer, the build and release
/// scripts that embed and sign the framework, and the rule that the snapshot path never starts
/// the updater. The scripts and sources are read as text (nothing here touches the network or
/// the keychain), so these tests guard the pattern, not a run of the release.
@Suite("Automatic updates")
struct UpdateTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The lines of a script or source file that are not whole-line comments.
    private static func codeLines(_ path: String) throws -> [String] {
        try text(path).split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private static func index(of needle: String, in lines: [String], after start: Int = 0) -> Int? {
        lines.indices.first { $0 >= start && lines[$0].contains(needle) }
    }

    // MARK: Info.plist

    @Test func infoPlistCarriesTheUpdateSettings() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
        #expect(plist["SUFeedURL"] as? String
                == "https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/latest/download/appcast.xml")
        #expect(plist["SUPublicEDKey"] as? String == "A+sSRMIu/QaRdklm4R4iQKYEIy6tCxtzosfQu8LsyEw=")
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(plist["SUEnableSystemProfiling"] as? Bool == false)
        // The update archive's signature is checked before the disk image is opened, and the feed
        // itself must be signed with the same key.
        #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(plist["SURequireSignedFeed"] as? Bool == true)
        // Release notes are plain HTML: no scripts, no extra link schemes.
        #expect(plist["SUEnableJavaScript"] == nil)
        #expect(plist["SUAllowedURLSchemes"] == nil)
    }

    // MARK: make-appcast.sh

    private struct ScriptResult {
        let status: Int32
        let stderr: String
    }

    private static func makeAppcast(_ arguments: [String]) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [root.appendingPathComponent("scripts/make-appcast.sh").path] + arguments
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(status: process.terminationStatus, stderr: String(decoding: message, as: UTF8.self))
    }

    /// What an appcast item says, read with XMLParser as Sparkle's feed readers would.
    private final class AppcastReader: NSObject, XMLParserDelegate {
        var items = 0
        var fields: [String: String] = [:]
        var enclosure: [String: String] = [:]
        private var inItem = false
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            buffer = ""
            if elementName == "item" { inItem = true; items += 1 }
            if inItem, elementName == "enclosure" { enclosure = attributeDict }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if inItem { fields[elementName] = buffer }
            if elementName == "item" { inItem = false }
            buffer = ""
        }
    }

    private static func read(_ file: URL) throws -> AppcastReader {
        let parser = try #require(XMLParser(contentsOf: file))
        let reader = AppcastReader()
        parser.delegate = reader
        #expect(parser.parse(), "the appcast is not well-formed XML: \(parser.parserError?.localizedDescription ?? "")")
        return reader
    }

    private static let validArguments = [
        "--version", "0.1.2", "--build", "57",
        "--url", "https://example.test/releases/download/v0.1.2/UploadTheFile.dmg?a=1&b=2",
        "--signature", "7cLALFUHSwvEJWSkV8aMreoBe4fhRa4FncC5NoThKxwThL6FDR7hTiPJh1fo2uagnPogisnQsgFgq6mGkt2RBw==",
        "--length", "1623481",
        "--date", "Mon, 16 Nov 2026 12:00:00 +0000",
    ]

    @Test func appcastHasOneItemWithEveryField() async throws {
        try await withTempDirectory { directory in
            let notes = try writeFile("notes.html", in: directory, contents: "<h2>What's new</h2>\n<ul><li>Fewer clicks &amp; more speed</li></ul>\n")
            let output = directory.appendingPathComponent("out/appcast.xml")
            let result = try Self.makeAppcast(Self.validArguments + ["--notes", notes.path, "--output", output.path])
            #expect(result.status == 0, "\(result.stderr)")

            let reader = try Self.read(output)
            #expect(reader.items == 1)
            #expect(reader.fields["title"] == "Version 0.1.2")
            #expect(reader.fields["sparkle:version"] == "57")
            #expect(reader.fields["sparkle:shortVersionString"] == "0.1.2")
            #expect(reader.fields["sparkle:minimumSystemVersion"] == "14.0.0")
            #expect(reader.fields["pubDate"] == "Mon, 16 Nov 2026 12:00:00 +0000")
            #expect(reader.enclosure["url"] == "https://example.test/releases/download/v0.1.2/UploadTheFile.dmg?a=1&b=2")
            #expect(reader.enclosure["sparkle:edSignature"]
                    == "7cLALFUHSwvEJWSkV8aMreoBe4fhRa4FncC5NoThKxwThL6FDR7hTiPJh1fo2uagnPogisnQsgFgq6mGkt2RBw==")
            #expect(reader.enclosure["length"] == "1623481")
            #expect(reader.enclosure["type"] == "application/octet-stream")
            let description = try #require(reader.fields["description"])
            #expect(description.contains("<h2>What's new</h2>"))
            #expect(description.contains("Fewer clicks &amp; more speed"))
        }
    }

    @Test func appcastKeepsNotesThatContainACDATAEnd() async throws {
        try await withTempDirectory { directory in
            let notes = try writeFile("notes.html", in: directory, contents: "<p>a ]]> b</p>\n")
            let output = directory.appendingPathComponent("appcast.xml")
            let result = try Self.makeAppcast(Self.validArguments + ["--notes", notes.path, "--output", output.path])
            #expect(result.status == 0, "\(result.stderr)")
            let reader = try Self.read(output)
            #expect(reader.fields["description"]?.contains("<p>a ]]> b</p>") == true)
        }
    }

    @Test func appcastUsesAGivenMinimumSystem() async throws {
        try await withTempDirectory { directory in
            let notes = try writeFile("notes.html", in: directory, contents: "<p>x</p>")
            let output = directory.appendingPathComponent("appcast.xml")
            let result = try Self.makeAppcast(Self.validArguments + ["--min-system", "15.0.0", "--notes", notes.path, "--output", output.path])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(try Self.read(output).fields["sparkle:minimumSystemVersion"] == "15.0.0")
        }
    }

    @Test func appcastRefusesMissingOrBadInputsAndWritesNothing() async throws {
        try await withTempDirectory { directory in
            let notes = try writeFile("notes.html", in: directory, contents: "<p>x</p>")
            let empty = try writeFile("empty.html", in: directory, contents: "")
            let output = directory.appendingPathComponent("appcast.xml")
            let complete: [(String, String)] = [
                ("--version", "0.1.2"), ("--build", "57"),
                ("--url", "https://example.test/UploadTheFile.dmg"),
                ("--signature", "c2lnbmF0dXJl=="), ("--length", "1000"),
                ("--notes", notes.path), ("--output", output.path),
            ]
            /// The complete argument list, without `dropping`, with `replacing`'s value.
            func arguments(dropping: String? = nil, replacing: (String, String)? = nil) -> [String] {
                complete.flatMap { name, value -> [String] in
                    if name == dropping { return [] }
                    if let replacing, replacing.0 == name { return [name, replacing.1] }
                    return [name, value]
                }
            }

            // The complete set works, so each refusal below is because of the one change.
            #expect(try Self.makeAppcast(arguments()).status == 0)
            try FileManager.default.removeItem(at: output)

            for name in complete.map(\.0) {
                let result = try Self.makeAppcast(arguments(dropping: name))
                #expect(result.status != 0, "\(name) is missing but the script succeeded")
                #expect(result.stderr.contains(name), "\(name): \(result.stderr)")
            }
            let bad: [(String, String)] = [
                ("--length", "12x"), ("--length", "0"), ("--build", "abc"),
                ("--build", "5.7"), ("--build", "."),
                ("--url", "http://example.test/UploadTheFile.dmg"),
                ("--signature", "not base64!"),
                ("--notes", directory.appendingPathComponent("missing.html").path),
                ("--notes", empty.path),
            ]
            for (name, value) in bad {
                let result = try Self.makeAppcast(arguments(replacing: (name, value)))
                #expect(result.status != 0, "\(name) \(value) was accepted")
            }
            let unknown = try Self.makeAppcast(arguments() + ["--bogus", "1"])
            #expect(unknown.status != 0)
            #expect(!FileManager.default.fileExists(atPath: output.path), "a refused run left a file behind")
        }
    }

    // MARK: build-app.sh

    @Test func buildScriptEmbedsTheFrameworkAndRemovesItsXPCServices() throws {
        let lines = try Self.codeLines("scripts/build-app.sh")
        let source = try #require(lines.first { $0.hasPrefix("SPARKLE_SRC=") }, "build-app.sh does not name the framework's source")
        #expect(source.contains(".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"))
        let destination = try #require(lines.first { $0.hasPrefix("FRAMEWORK=") })
        #expect(destination.contains("$APP/Contents/Frameworks/Sparkle.framework"))
        // ditto keeps the framework's symlinks; a plain copy breaks its signature.
        let copy = try #require(lines.firstIndex { $0.hasPrefix("ditto") && $0.contains("\"$SPARKLE_SRC\"") && $0.contains("\"$FRAMEWORK\"") },
                                "build-app.sh does not copy Sparkle.framework with ditto")
        // The app is not sandboxed, so the XPC services are never used; Sparkle documents removing them.
        let removal = try #require(lines.firstIndex { $0.hasPrefix("rm -rf") && $0.contains("XPCServices") }, "XPCServices are not removed")
        #expect(lines[removal].contains("\"$FRAMEWORK/Versions/B/XPCServices\""))
        #expect(lines[removal].contains("\"$FRAMEWORK/XPCServices\""), "the XPCServices link must go with the folder")
        #expect(copy < removal)
    }

    @Test func buildScriptSignsTheFrameworkInsideOutWithoutDeep() throws {
        let lines = try Self.codeLines("scripts/build-app.sh")
        let removal = try #require(lines.firstIndex { $0.hasPrefix("rm -rf") && $0.contains("XPCServices") })
        let autoupdate = try #require(Self.index(of: "\"$FRAMEWORK/Versions/B/Autoupdate\"", in: lines, after: removal), "Autoupdate is not signed")
        let updater = try #require(Self.index(of: "\"$FRAMEWORK/Versions/B/Updater.app\"", in: lines, after: autoupdate), "Updater.app is not signed")
        let framework = try #require(lines.indices.first { $0 > updater && lines[$0].hasPrefix("codesign") && lines[$0].hasSuffix("\"$FRAMEWORK\"") },
                                     "the framework itself is not signed")
        let app = try #require(lines.indices.last { lines[$0].contains("--sign \"$IDENTITY\" \"$APP\"") }, "the app is not signed")
        #expect(framework < app, "the app must be signed after the framework it contains")

        for line in lines where line.contains("codesign") && line.contains("--sign") {
            #expect(!line.contains("--deep"), "signing with --deep: \(line)")
        }
        // The same identity, hardened-runtime setting and timestamp as the app.
        for index in [autoupdate, updater, framework] {
            let line = lines[index]
            #expect(line.contains("$RUNTIME") && line.contains("$TIMESTAMP") && line.contains("--sign \"$IDENTITY\""), "\(line)")
        }
    }

    @Test func hardenedRuntimeIsOnlyDroppedForAdHocBuilds() throws {
        let lines = try Self.codeLines("scripts/build-app.sh")
        // A Developer ID build keeps the hardened runtime; an ad-hoc framework cannot pass library
        // validation under it, so an ad-hoc build runs without it.
        let identity = try #require(Self.index(of: "if [ -n \"${SIGN_IDENTITY:-}\" ]", in: lines))
        let developerID = try #require(Self.index(of: "RUNTIME=\"--options runtime\"", in: lines, after: identity))
        let otherwise = try #require(lines.indices.first { $0 > developerID && lines[$0].trimmingCharacters(in: .whitespaces) == "else" })
        let adHoc = try #require(Self.index(of: "RUNTIME=\"\"", in: lines, after: otherwise))
        #expect(developerID < otherwise && otherwise < adHoc)
        for line in lines where line.contains("codesign") && line.contains("--sign") {
            #expect(!line.contains("--options runtime"), "the runtime flag must come from $RUNTIME: \(line)")
        }
        for line in lines where line.contains("codesign") && line.contains("--sign \"$IDENTITY\"") {
            #expect(line.contains("$RUNTIME"), "no $RUNTIME in: \(line)")
        }
    }

    // MARK: release.sh

    @Test func releaseRequiresNotesAndSignsTheDiskImageAfterStapling() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let notes = try #require(Self.index(of: "RELEASE_NOTES_HTML:?", in: lines), "release.sh does not require RELEASE_NOTES_HTML")
        let build = try #require(lines.firstIndex { $0.hasPrefix("UNIVERSAL=1") && $0.contains("scripts/build-app.sh") })
        #expect(notes < build, "the notes are checked before the long build")
        #expect(lines.contains { $0.hasPrefix("SPARKLE_ACCOUNT=\"uploadthefile-mac\"") })

        let staple = try #require(Self.index(of: "stapler staple \"$DMG\"", in: lines))
        let sign = try #require(Self.index(of: "sign_update", in: lines, after: staple), "the DMG is not signed for Sparkle after stapling")
        #expect(lines[sign].contains("--account \"$SPARKLE_ACCOUNT\""))
        let appcast = try #require(Self.index(of: "scripts/make-appcast.sh", in: lines, after: sign))
        let call = lines[appcast..<min(appcast + 4, lines.count)].joined(separator: " ")
        #expect(call.contains("--notes \"$RELEASE_NOTES_HTML\""))
        #expect(call.contains("--url \"$DOWNLOAD_URL\""))
        #expect(call.contains("--signature \"$SIGNATURE\""))
        #expect(call.contains("$OUT/appcast.xml"))
        let download = try #require(lines.first { $0.hasPrefix("DOWNLOAD_URL=") })
        #expect(download.contains("https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/download/v$VERSION/UploadTheFile.dmg"))
    }

    @Test func releaseChecksTheKeyTheSignatureAndTheFrameworkBeforeAnythingIsPublished() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let key = try #require(lines.firstIndex { $0.contains("generate_keys") && $0.contains("--account \"$SPARKLE_ACCOUNT\" -p") })
        let comparison = try #require(lines.firstIndex { $0.contains("SUPublicEDKey") && $0.contains("PlistBuddy") }, "the app's public key is not read")
        #expect(key < comparison)
        #expect(lines.contains { $0.contains("\"$APP_KEY\" = \"$KEYCHAIN_KEY\"") }, "the app's public key is not compared with the keychain's")
        #expect(lines.contains { $0.contains("sign_update") && $0.contains("--verify") }, "the signature is not verified")
        // The framework in the shipped app: same team, hardened runtime, no XPC services.
        #expect(lines.contains { $0.contains("XPCServices") && $0.contains("SPARKLE_FRAMEWORK") }, "XPC services are not checked")
        #expect(lines.contains { $0.contains("TeamIdentifier") }, "the team is not checked")
        #expect(lines.contains { $0.contains("flags=.*runtime") && $0.contains("$PART") }, "the hardened runtime is not checked on the framework")
        for line in lines where line.contains("codesign") && line.contains("--sign") {
            #expect(!line.contains("--deep"), "\(line)")
        }
        // The private key is only ever used by sign_update, through the keychain: generate_keys only
        // prints the public key, and no key file is read or written.
        for line in lines {
            #expect(!line.contains("--ed-key-file"), "\(line)")
            if line.contains("generate_keys") && !line.hasPrefix("for ") { #expect(line.contains(" -p"), "\(line)") }
        }
    }

    // MARK: Gates in release.sh

    /// The index of the first code line that contains every needle.
    private static func line(_ lines: [String], _ needles: String...) -> Int? {
        lines.firstIndex { line in needles.allSatisfy { line.contains($0) } }
    }

    @Test func releaseRefusesAnUnsignedFeedAndAnUnverifiedDiskImageSettingBeforePublishing() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        for key in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            let check = try #require(Self.line(lines, key, "PlistBuddy"), "\(key) is not read from the built app")
            #expect(lines[check].contains("= \"true\""), "\(key) must be true: \(lines[check])")
        }
        // Settings that widen what the update window may load or open must stay absent.
        for key in ["SUEnableJavaScript", "SUAllowedURLSchemes"] {
            let check = try #require(Self.line(lines, key, "PlistBuddy"), "\(key) is not checked")
            #expect(lines[check].contains("&& fail"), "\(key) must be refused when present: \(lines[check])")
        }
    }

    @Test func releaseSignsTheAppcastInPlaceAndVerifiesItBeforeXmllint() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let make = try #require(Self.line(lines, "scripts/make-appcast.sh"))
        let sign = try #require(lines.indices.first { $0 > make && lines[$0].contains("sign_update") && lines[$0].contains("\"$OUT/appcast.xml\"") && !lines[$0].contains("--verify") },
                                "the appcast is not signed")
        #expect(lines[sign].contains("--account \"$SPARKLE_ACCOUNT\""))
        let verify = try #require(lines.indices.first { $0 > sign && lines[$0].contains("sign_update") && lines[$0].contains("--verify") && lines[$0].contains("\"$OUT/appcast.xml\"") },
                                  "the signed appcast is not verified")
        let lint = try #require(Self.line(lines, "xmllint", "\"$OUT/appcast.xml\""))
        #expect(make < sign && sign < verify && verify < lint)
        #expect(lines[verify].contains("fail"), "a failed verification must stop the release")
    }

    @Test func releaseRefusesAWrongBuildNumberBeforeBuilding() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let build = try #require(lines.firstIndex { $0.hasPrefix("UNIVERSAL=1") && $0.contains("scripts/build-app.sh") })
        let tree = try #require(Self.line(lines, "check_tree_matches_commit \"Before the build:\""))
        let shallow = try #require(Self.line(lines, "rev-parse --is-shallow-repository"), "a shallow clone is not refused")
        let branch = try #require(Self.line(lines, "symbolic-ref", "HEAD"), "the branch is not checked")
        #expect(lines[branch].contains("main"))
        let ancestor = try #require(Self.line(lines, "merge-base --is-ancestor", "$PREV_TAG", "HEAD"), "the previous release is not required in the history")
        let tags = try #require(Self.line(lines, "git tag --list 'v*'"))
        for index in [shallow, branch, tags, ancestor] {
            #expect(index > tree && index < build, "gate after the build or before the tree check: \(lines[index])")
        }
    }

    @Test func releaseTakesTheMinimumSystemFromTheBuiltApp() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let read = try #require(Self.line(lines, "LSMinimumSystemVersion", "PlistBuddy", "$APP/Contents/Info.plist"))
        let call = try #require(Self.line(lines, "scripts/make-appcast.sh"))
        #expect(read < call)
        #expect(lines.contains { $0.contains("MIN_SYSTEM=\"$MIN_SYSTEM.0\"") }, "x.y is not extended to x.y.0")
        let arguments = lines[call..<min(call + 5, lines.count)].joined(separator: " ")
        #expect(arguments.contains("--min-system \"$MIN_SYSTEM\""))
    }

    @Test func releaseRefusesNotesThatAreStaleOrLoadRemoteFiles() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let build = try #require(lines.firstIndex { $0.hasPrefix("UNIVERSAL=1") && $0.contains("scripts/build-app.sh") })
        let version = try #require(Self.line(lines, "grep -qF \"$VERSION\" \"$RELEASE_NOTES_HTML\""), "the notes need not name the version")
        let sources = try #require(lines.firstIndex { $0.contains("grep") && $0.contains("src") && $0.contains("\"$RELEASE_NOTES_HTML\"") }, "remote resources are not refused")
        #expect(version < build && sources < build)
    }

    @Test func releaseComparesTheEmbeddedFrameworkWithThePinnedVersion() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let pinned = try #require(Self.line(lines, "Package.resolved", "sparkle"), "the pinned Sparkle version is not read")
        let embedded = try #require(Self.line(lines, "Sparkle.framework", "Versions/B/Resources/Info.plist", "CFBundleShortVersionString")
                                    ?? Self.line(lines, "$SPARKLE_FRAMEWORK/Versions/B/Resources/Info.plist"))
        let compare = try #require(lines.indices.first { $0 > max(pinned, embedded) && lines[$0].contains("fail") && lines[$0].contains("Sparkle") })
        #expect(compare > pinned)
    }

    @Test func releaseReportsSignUpdateErrorsAndPinsTheTeamAndTools() throws {
        let lines = try Self.codeLines("scripts/release.sh")
        let sign = try #require(lines.firstIndex { $0.hasPrefix("SIGNATURE=") && $0.contains("sign_update") })
        #expect(lines[sign].contains("|| {") && lines[sign].contains("printf '%s\\n' \"$SIGNATURE\" >&2") && lines[sign].contains("fail \"sign_update failed\""),
                "sign_update's output must be shown when it fails: \(lines[sign])")
        #expect(lines.contains { $0.contains("/usr/bin/stat -f %z") }, "stat must be the system one")
        #expect(!lines.contains { $0.contains(" stat ") && !$0.contains("/usr/bin/stat") })
        #expect(lines.contains { $0.contains("G323SXP8VG") && $0.contains("APP_TEAM") }, "the team is not pinned")
    }

    @Test func buildScriptTakesTheFrameworkFromTheSliceItLinked() throws {
        let lines = try Self.codeLines("scripts/build-app.sh")
        let universal = try #require(lines.firstIndex { $0.contains("SPARKLE_SRC=\".build-arm64/artifacts/") })
        let fallback = try #require(lines.firstIndex { $0.hasPrefix("SPARKLE_SRC=") && $0.contains(".build/artifacts/") })
        #expect(universal > 0 && fallback > 0)
        let missing = try #require(lines.firstIndex { $0.contains("Missing $SPARKLE_SRC") }, "a missing framework is not reported")
        #expect(missing > max(universal, fallback))
    }

    @Test func adHocBuildsDoNotPollTheLiveFeed() throws {
        let lines = try Self.codeLines("scripts/build-app.sh")
        let adHoc = try #require(Self.line(lines, "IDENTITY=\"-\""))
        let removal = try #require(Self.line(lines, "Delete :SUFeedURL"), "an ad-hoc build keeps SUFeedURL")
        let developerID = try #require(Self.line(lines, "IDENTITY=\"$SIGN_IDENTITY\""))
        #expect(removal > adHoc && removal > developerID)
        #expect(lines[removal].contains("$APP/Contents/Info.plist"))
        // The release gate in release.sh keeps the feed in the signed build.
        let release = try Self.codeLines("scripts/release.sh")
        #expect(release.contains { $0.contains("SUFeedURL") && $0.contains("https://") })
    }

    @Test func appcastScriptWritesWithPrintfBecauseEchoExpandsBackslashes() throws {
        for line in try Self.codeLines("scripts/make-appcast.sh") {
            #expect(!line.contains("echo "), "\(line)")
        }
    }

    @Test func publishedCheckComparesTheFeedAndTheDiskImageWithTheBuild() throws {
        let lines = try Self.codeLines("scripts/check-published.sh")
        #expect(lines.contains { $0.contains("/latest/download/appcast.xml") })
        #expect(lines.contains { $0.contains("/download/v$VERSION/UploadTheFile.dmg") })
        #expect(lines.contains { $0.contains("cmp") && $0.contains("\"$OUT/appcast.xml\"") })
        #expect(lines.contains { $0.contains("shasum -a 256") })
        #expect(lines.contains { $0.contains("UploadTheFile.dmg.sha256") })
        // It only reads: nothing is uploaded, deleted or signed from here.
        for line in lines {
            #expect(!line.contains("gh release") && !line.contains("--upload-file") && !line.contains("sign_update"), "\(line)")
        }
    }

    // MARK: Docs and the cask template

    @Test func releasingDocsDescribeTheFixedAppcastKeyRotationAndTheCaskTiming() throws {
        let releasing = try Self.text("docs/RELEASING.md")
        #expect(releasing.contains("scripts/check-published.sh"))
        #expect(releasing.contains("never be edited by hand"))
        #expect(releasing.contains("SUPublicEDKey"))
        #expect(releasing.contains("rotat"), "key rotation is not described")
        #expect(releasing.contains("auto_updates true"))
        #expect(releasing.contains("Allow"))
        #expect(!releasing.contains("copies already installed cannot be"), "the key-loss claim is wrong: a signed DMG can carry a new key")
        #expect(!releasing.contains("a new release always\n   compares as newer"), "the build-number claim needs its conditions")
        let development = try Self.text("docs/DEVELOPMENT.md")
        #expect(development.contains("defaults write com.smilemasktechnology.uploadthefile SUEnableAutomaticChecks -bool NO"))
        #expect(development.contains("IP address"))
        #expect(!development.contains("whatever the feed says"))
        let readme = try Self.text("README.md")
        #expect(readme.contains("right-click menu"))
    }

    @Test func theCaskTemplateKeepsAutoUpdatesAndRemovesTheCacheOnZap() throws {
        let cask = try Self.text("packaging/homebrew/upload-the-file.rb")
        #expect(cask.contains("auto_updates true"))
        #expect(cask.contains("~/Library/Caches/com.smilemasktechnology.uploadthefile"))
        #expect(cask.contains("~/Library/HTTPStorages/com.smilemasktechnology.uploadthefile"))
    }

    // MARK: Notices, the snapshot path

    @Test func noticesNameSparkleAndIncludeItsLicenceInFull() throws {
        let notices = try Self.text("THIRD_PARTY_NOTICES.txt")
        #expect(notices.contains("\nSparkle "), "THIRD_PARTY_NOTICES.txt lacks Sparkle: run scripts/make-notices.sh")
        #expect(notices.contains("Copyright (c) 2006-2013 Andy Matuschak."))
        // The licences of the code Sparkle bundles come with its LICENSE file.
        #expect(notices.contains("EXTERNAL LICENSES"))
        #expect(notices.contains("bspatch.c and bsdiff.c"))
    }

    @Test func theSnapshotPathNeverStartsTheUpdater() throws {
        // The snapshot branch leaves the process before the app (and its delegate) exists.
        let main = try Self.codeLines("Sources/UploadTheFile/main.swift")
        let snapshots = try #require(Self.index(of: "Snapshots.requestedDirectory", in: main))
        let exit = try #require(Self.index(of: "exit(Snapshots.run", in: main, after: snapshots))
        let launch = try #require(Self.index(of: "UploadTheFileApp.main()", in: main))
        #expect(exit < launch)

        // Only the app delegate's launch creates the updater; the snapshots file has no part in it.
        let snapshotSource = try Self.text("Sources/UploadTheFile/Snapshots.swift")
        #expect(!snapshotSource.contains("Sparkle") && !snapshotSource.contains("AppUpdates") && !snapshotSource.contains("StatusItemController"))
        var creations: [String] = []
        let sources = Self.root.appendingPathComponent("Sources/UploadTheFile")
        for path in try FileManager.default.subpathsOfDirectory(atPath: sources.path) where path.hasSuffix(".swift") {
            let source = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            if source.contains("AppUpdates()") { creations.append(path) }
            if source.contains("SPUStandardUpdaterController(") { #expect(path == "Updates.swift", "\(path) creates a Sparkle updater") }
        }
        #expect(creations == ["UploadTheFileApp.swift"])
        let app = try Self.text("Sources/UploadTheFile/UploadTheFileApp.swift")
        let launchFunction = try #require(app.range(of: "func applicationDidFinishLaunching"))
        let creation = try #require(app.range(of: "AppUpdates()"))
        #expect(creation.lowerBound > launchFunction.lowerBound)
    }

    @Test func theMenuOffersCheckForUpdatesAndTheUpdaterSupportsGentleReminders() throws {
        let menu = try Self.text("Sources/UploadTheFile/StatusItemController.swift")
        #expect(menu.contains("updates.checkForUpdatesItem()"))
        let updates = try Self.text("Sources/UploadTheFile/Updates.swift")
        #expect(updates.contains("title: pending.menuTitle"))
        #expect(updates.contains("#selector(SPUStandardUpdaterController.checkForUpdates(_:))"))
        #expect(updates.contains("supportsGentleScheduledUpdateReminders: Bool { true }"))
        #expect(updates.contains("startingUpdater: true"))
    }

    @Test func aScheduledUpdateNeverTakesTheFocusAndIsAnnouncedInsteadWhenSparkleDoesNotShowIt() throws {
        let lines = try Self.codeLines("Sources/UploadTheFile/Updates.swift")
        // Sparkle shows a scheduled update itself only when it is in immediate focus (right after
        // launch); in every other case it is announced with the menu item and a notification.
        let handle = try #require(Self.line(lines, "standardUserDriverShouldHandleShowingScheduledUpdate"))
        #expect(lines[handle..<min(handle + 4, lines.count)].contains { $0.trimmingCharacters(in: .whitespaces) == "immediateFocus" },
                "a scheduled update must be shown by Sparkle only when it is in immediate focus")
        #expect(lines.contains { $0.contains("standardUserDriverWillHandleShowingUpdate") })
        #expect(lines.contains { $0.contains("pending.record(version:") })
        #expect(lines.contains { $0.contains("Notifier.post") && $0.contains("PendingUpdate.notification") || $0.contains("PendingUpdate.notificationActionKey") })
        let finish = try #require(Self.line(lines, "standardUserDriverWillFinishUpdateSession"))
        #expect(lines[finish..<min(finish + 4, lines.count)].contains { $0.contains("pending.clear()") })
        // Sparkle activates the app for a check the person asked for; nothing here does.
        for line in lines {
            #expect(!line.contains("AppActivation") && !line.contains("activate("), "\(line)")
        }
    }

    @Test func theUpdaterDelegateKeepsTheFeedAndHoldsTheRelaunchWhilePublishing() throws {
        let lines = try Self.codeLines("Sources/UploadTheFile/Updates.swift")
        #expect(lines.contains { $0.contains("updaterDelegate: self") }, "the delegate is not given to the updater")
        let feed = try #require(Self.line(lines, "feedURLString(for"))
        #expect(lines[feed..<min(feed + 4, lines.count)].contains { $0.contains("SUFeedURL") },
                "the feed must come from Info.plist, not from user defaults")
        let relaunch = try #require(Self.line(lines, "shouldPostponeRelaunchForUpdate"))
        #expect(lines.contains { $0.contains("untilInvokingBlock") })
        #expect(lines[relaunch..<min(relaunch + 6, lines.count)].contains { $0.contains("relaunchHold.request(isBusy:") && $0.contains("session.isActive") })
        #expect(lines.contains { $0.contains("relaunchHold.busyChanged(isBusy:") && $0.contains("session.isActive") })
    }
}
