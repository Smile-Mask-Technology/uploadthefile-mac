# Developing Upload the File for Mac

One Swift package, four parts:

| Part | What it is |
| --- | --- |
| `UptfKit` | The library: browser sign-in (OAuth 2.1 + PKCE), the API client generated from the upload.tf OpenAPI spec, folder zipping with exclusions, the local index of published files |
| `uptf` | The command-line tool |
| `UploadTheFile` | The menu bar app (AppKit status item + SwiftUI) |
| `UploadTheFileCore` | The app's testable logic: the flow from file to link, confirmations, row state, messages, window sizing rules |

Requirements: macOS 14 or newer and Swift 6. The Command Line Tools are enough; Xcode is not needed.

## Build

```sh
swift build -c release                # .build/release/uptf
scripts/build-app.sh                  # build/Upload the File.app (ad-hoc signed, this Mac only)
UNIVERSAL=1 scripts/build-app.sh      # Apple silicon + Intel
```

The bundle holds the app (`Contents/MacOS/UploadTheFile`), the CLI (`Contents/Resources/uptf`),
Sparkle (`Contents/Frameworks/Sparkle.framework`, see Updates below), the menu bar icons
(`Contents/Resources/MenuBarIcons`, template PDFs) and the logo
(`Contents/Resources/BrandMark.pdf`). The icons and the app icon are generated from the website's
logo geometry by `scripts/make-menubar-icons.swift` (see `Resources/MenuBarIcons/README.md`).

To run against a local upload.tf server:

```sh
UPTF_SITE=http://localhost:3000 "build/Upload the File.app/Contents/MacOS/UploadTheFile"
UPTF_SITE=http://localhost:3000 .build/release/uptf login
```

`UPTF_HOME` moves the app's JSON files to another folder (useful in tests).

## Tests

```sh
scripts/test.sh
```

Swift Testing, no network. With Xcode installed this is `swift test`. With only the Command Line
Tools, `swift test` builds the tests but runs none and still exits 0, so the script runs the built
bundle through `scripts/run-tests.swift` and returns the real result. CI runs the same script on
GitHub's macOS runners.

The script also fails when the run reports no tests, or fewer than the number in
`scripts/min-test-count` (checked when no filter arguments are given), so a test target that stops
running cannot leave a green result. Raise that number when you add tests.

`scripts/snapshots.sh` renders every screen of the app, light and dark, to `build/snapshots/` (a
DEBUG-only mode; release builds do not contain it). The images in `docs/images` come from there.

## Releases

See [RELEASING.md](RELEASING.md): `scripts/release.sh` builds the universal app, signs it with the
Developer ID, has Apple notarize the app and the DMG, and writes `build/release/UploadTheFile.dmg`
and the update feed `build/release/appcast.xml`.
The asset name never changes, so `releases/latest/download/UploadTheFile.dmg` is always the newest.

## Updates

The app updates itself with [Sparkle 2](https://sparkle-project.org). `Sparkle.framework` comes from
the package's binary artifact (`.build/artifacts/sparkle/Sparkle`); `scripts/build-app.sh` copies it
to `Contents/Frameworks` with `ditto` (the symlinks inside must survive), deletes its XPC services
(they are only for sandboxed apps) and signs it inside out: the `Autoupdate` helper, `Updater.app`,
the framework, then the app, never with `--deep`. A Developer ID build keeps the hardened runtime. An
ad-hoc build has no hardened runtime: library validation, part of it, refuses a framework that has no
team in its signature.

- **Feed.** `SUFeedURL` in `Resources/Info.plist` is
  `https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/latest/download/appcast.xml`:
  the appcast attached to the newest GitHub release. `scripts/make-appcast.sh` writes it (one item:
  version, build, minimum macOS, DMG address, EdDSA signature, release notes).
- **Key.** `SUPublicEDKey` is the public half of the update signing key. An update that is not signed
  by the matching private key is refused, whatever the feed says.
- **When.** `SUEnableAutomaticChecks` is on, so the first check needs no question; Sparkle then
  checks about every 24 hours and offers the new version in its own window. The app is a menu bar
  app, so `AppUpdates` (`Sources/UploadTheFile/Updates.swift`) declares gentle-reminder support and
  brings the app to the front when Sparkle shows an alert. **Check for Updates…** is in the
  right-click menu of the menu bar icon, and is disabled while a check runs.
- **What is sent.** Sparkle's request for the feed carries the app's name and version in the
  `User-Agent`, and no other information about the Mac (`SUEnableSystemProfiling` is off).
- **Not in snapshots.** `AppUpdates` is created when the app finishes launching; the
  `--render-snapshots` mode exits before the app starts, so it never starts the updater or opens a
  connection. A binary that is not inside an `.app` with a feed (for example `swift run`) does not
  start it either.

## How it works

**Sign-in.** OAuth 2.1 with PKCE in the default browser, redirect to
`http://127.0.0.1:<random port>/callback`, tokens bound to `<site>/api/v1`. The client registers
itself once per site (dynamic client registration); if the server no longer knows the registration,
the stored one is dropped and sign-in registers again. Redirects are never followed for API and
OAuth requests. Signing out revokes the grant on the server
(RFC 7009), then forgets it locally.

**Stored on the Mac.**

| What | Where |
| --- | --- |
| Access and refresh tokens | Keychain, service `com.smilemasktechnology.uploadthefile`, one item per site |
| OAuth client id (public) | `~/Library/Application Support/UploadTheFile/oauth-clients.json` |
| Which local file or folder is which link | `~/Library/Application Support/UploadTheFile/published-index.json` |

The index is keyed by the page's immutable id, so a rename on the website keeps the local link. The
app and `uptf` share the Keychain item and the index.

The Keychain item lives in the file-based login keychain (the data-protection keychain needs a
provisioning profile, which a command-line tool cannot carry), where the accessibility attribute set
on creation has no effect. Its access list trusts only the program that created it, so macOS asks
once for each separately signed program (the app, `uptf`) that reads it.

The app and `uptf` refresh the access token under an exclusive lock on `refresh.lock` (`flock`, in
the same Application Support folder). A refresh token works once and a second use revokes the whole
grant, so whichever program gets the lock second reads the tokens the first one saved instead of
refreshing again. A program that cannot get the lock within 30 seconds reports "not signed in"
without touching the stored tokens.

**Folders.** Zipped with `/usr/bin/zip`. Hidden files, `.git`, `node_modules`, `.env*`, keys and
certificates are left out, and the exact list is shown first. Paths such as `~/.ssh`,
`~/Library/Keychains`, `~/.gnupg` and `~/.aws` need an explicit confirmation (the CLI refuses them).
Files over 50 MB are refused before uploading.

**Sandbox.** The release app runs with the hardened runtime, without exceptions, and without the App
Sandbox: it runs `/usr/bin/zip` on paths the user picks anywhere on disk and shares its Keychain
item and index with the CLI. The entitlements file is empty on purpose (it must stay free of XML
comments; the system's parser rejects them).

**Rate limits.** Free accounts get 20 API reads and 20 writes per hour, shared by every app on the
account, so the clients are frugal and never retry on their own: the link list is one read, cached
for 10 minutes, and carries each link's password, email-gate and how-it-opens state, so a link's
settings window opens with no reads when the email gate is off (one read, for its message, when it
is on). A server whose list lacks those fields gets up to three reads per window, only for what is
missing (`uptf info --settings` follows the same rule). A change made in the window updates the
cached list, so the list shows it without another read. Publishing is one write (and one more read
only if the server's answer has no page id). HTTP 429 shows "Too many changes in a short time. Try again in
N minutes." (`uptf` exits with status 5).

**Finder.** Two macOS Services in `Resources/Info.plist`: **Publish with Upload the File** and
**Copy Upload the File Link** (no API request). The app refreshes the Services list at launch;
`/System/Library/CoreServices/pbs -update` forces it.

**Windows.** No window or popover takes its size from SwiftUI's ideal size
(`sizingOptions = [.preferredContentSize]`): during a drop, AppKit runs the drop animation in a
nested run loop, and a window that follows its content then loops its layout until AppKit throws.
Sizes are set explicitly after the content settles (`PopoverSizing`), drops start their work after
the drop animation, and `WindowSizingGuardTests` keeps it that way.

## `uptf` reference

```sh
uptf login | logout | status
uptf publish <path> [--name <name>] [--site] [--yes] [--no-copy]
uptf update <path>
uptf ls [--json]
uptf info <path-or-name> [--settings] [--json]
uptf rename <path-or-name> <new-name>
uptf password <path-or-name> set|remove
uptf gate <path-or-name> on|off [--message <text>]
uptf expiry <path-or-name> <ISO 8601 date>|never
uptf display <path-or-name> preview|preview_download|download
uptf delete <path-or-name> [--yes]
```

Exit status: `0` done, `1` failure (also a question answered No), `2` a date for `expiry` that
isn't valid, `3` not signed in, `4` refused by the plan, `5` too many changes in a short time, `64`
the command line wasn't understood (a missing or unknown argument or option; ArgumentParser's own
status), `130` stopped while running. A DMG install has the tool at
`/Applications/Upload the File.app/Contents/Resources/uptf`.

## Library

```swift
import UptfKit

let config = try UptfConfig()                 // https://uploadthefile.com, or UptfConfig.fromEnvironment()
let client = UptfClient(config: config)        // Keychain tokens
let pages = try await client.pages()
let index = try PublishedIndex(config: config)
let publisher = Publisher(client: client, index: index)
let plan = try publisher.prepare(URL(fileURLWithPath: "site"))
let outcome = try await publisher.publish(plan, name: "my-site", hostAsSite: true)
```

Everything throws `UptfError` (`.notSignedIn`, `.server`, `.rateLimited(retryAfter:)`, `.tooLarge`, …).

## Words

What people read in the app and in `uptf` follows [voice.md](voice.md).
