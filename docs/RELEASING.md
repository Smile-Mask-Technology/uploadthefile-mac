# Releasing

Everything runs on a Mac with the Command Line Tools (no Xcode needed).

## Once per Mac

- The **Developer ID Application** certificate for Smile Mask Technology FZE (G323SXP8VG) in the
  login keychain, plus Apple's Developer ID G2 intermediate
  (https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer).
  Check: `security find-identity -v -p codesigning` lists it.
- A notarytool keychain profile (the app-specific password is typed by the person, never stored
  in this repo or in CI):
  `xcrun notarytool store-credentials uptf-notary --apple-id <Apple ID> --team-id G323SXP8VG`
- The **update signing key** in the login keychain, account `uploadthefile-mac`. Its public half is
  `SUPublicEDKey` in `Resources/Info.plist`; every DMG offered through the appcast is signed with
  the private half, and so is the appcast itself. Check:
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account uploadthefile-mac -p` prints the
  public key (it never prints the private one). **Keep a backup** of the key in a password
  manager: `generate_keys --account uploadthefile-mac -x <file>` writes it to a file in clear text,
  so write that file outside this repository and outside any synced or backed-up folder (iCloud
  Drive, Dropbox and the like), store its content, then delete it (deleting a file on APFS is not
  secure erasure, so keep its lifetime short); `-f <file>` imports it on another
  Mac. Never put it in the repository, in CI, or in a chat.
  When `sign_update` asks for the keychain, choose **Allow** (once), not **Always Allow**: with
  "Always" any program running as you can sign updates without a prompt. A new Sparkle version
  brings new tool binaries and a new prompt.
- **If the key is lost or leaks.** Sparkle accepts an update when its EdDSA signature matches the
  installed app's `SUPublicEDKey`, or when the new app is signed by the same Developer ID identity
  as the installed one. So the key can be rotated: generate a new one, put its public half in
  `Resources/Info.plist` as `SUPublicEDKey`, and ship that release as a Developer ID-signed,
  notarized DMG signed with the new key (Sparkle's rotation rules:
  https://sparkle-project.org/documentation/#rotating-signing-keys). Installed copies then trust the
  new key from that release on. Only if both the key and the Developer ID identity are lost can
  installed copies no longer be updated by the app, and people must download the app again. The
  same two facts mean either one alone, together with control of the feed, is enough to push an
  update: keep both private.

## Each release

1. Set the version in `VERSION` (it must equal `UptfKitVersion.value`; a test checks it), commit.
   Write the release notes as an HTML file (a few `<h2>`, `<ul>` and `<p>`; Sparkle shows it in the
   update window; it must name the version and load nothing from the network, so no images).
2. Build, sign, notarize, staple and package:

   ```sh
   SIGN_IDENTITY="Developer ID Application: Smile Mask Technology FZE (G323SXP8VG)" \
   NOTARY_PROFILE=uptf-notary RELEASE_NOTES_HTML=release-notes.html scripts/release.sh
   ```

   It refuses to start without `RELEASE_NOTES_HTML`, and refuses notes that do not mention
   `VERSION` or that contain `src=` (the update window must not fetch anything). It refuses a
   shallow clone, a checkout that is not branch `main`, and a commit that does not contain the
   previous `v*` tag: the build number is the commit count, and only a full history of `main` that
   descends from the last release gives a number higher than the one before. It refuses a tree that
   differs from the
   commit (modified files, and files git does not know in
   `Sources`, `Resources`, `scripts`, `Package.swift`, `Package.resolved`, `VERSION`), runs the tests
   (which must report at least `scripts/min-test-count` of them), checks that the keychain holds the
   update signing key, builds a universal app (Apple silicon and Intel) with exactly the package
   versions in `Package.resolved`, and checks the tree again after the build. It then checks the app:
   both programs hold both architectures, the signature verifies
   (`codesign --verify --strict --deep`) with the hardened runtime and no entitlements, the team is
   `G323SXP8VG`, the bundle's
   version and `uptf --version` equal `VERSION`, and the app contains no snapshot code. For the
   updater it also checks that the app's `SUPublicEDKey` equals the keychain's public key, that
   `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` are on and `SUEnableJavaScript` and
   `SUAllowedURLSchemes` are absent, that the embedded Sparkle version is the one in
   `Package.resolved`, and that
   `Sparkle.framework` (with its `Autoupdate` and `Updater.app`) is signed by the same team as the
   app with the hardened runtime and has no `XPCServices`. It also checks that the app carries
   `LICENSE` and `THIRD_PARTY_NOTICES.txt` in `Contents/Resources` (the disk image holds only the
   app and the Applications link, no loose licence files). After that it has Apple notarize the
   app, builds the disk image with `scripts/make-dmg.sh` (a small window: the app on the left, an
   arrow, the Applications folder on the right; see "The disk image window" in
   [DEVELOPMENT.md](DEVELOPMENT.md)), signs it, has Apple notarize the DMG, staples both, checks
   Gatekeeper, signs the finished DMG for Sparkle
   (`sign_update`, verified straight away) and writes
   `build/release/UploadTheFile.dmg`, its `.sha256` and `build/release/appcast.xml` (one item: the
   version, the build number Sparkle compares, the app's minimum macOS, the DMG's address, its
   signature and size, and the release notes). Last it signs the appcast in place with the update
   key (`sign_update`) and verifies that signature. The signed appcast must
   never be edited by hand, not even a character of the notes: the app refuses a feed whose
   signature does not match, and for about 20 days shows no update at all. To change anything, fix
   the cause and run the script again. The DMG name never changes, so the
   README's download link (`releases/latest/download/UploadTheFile.dmg`) always serves the newest
   release; never rename the asset.
3. Tag and publish on GitHub, with the appcast attached (the app reads
   `releases/latest/download/appcast.xml`, which moves to the newest published release):

   ```sh
   git tag -s v<version> -m "Upload the File <version>"
   git push origin main v<version>
   gh release create v<version> build/release/UploadTheFile.dmg \
     build/release/UploadTheFile.dmg.sha256 build/release/appcast.xml \
     --title "Upload the File <version>" --notes-file <notes.md>
   ```

   The appcast's DMG address is `releases/download/v<version>/UploadTheFile.dmg`, so the tag must
   be exactly `v<version>`. A release that is published as a draft or pre-release is not "latest"
   and is not offered. Attach the appcast exactly as `scripts/release.sh` wrote it, and attach it
   to every release made from the web page too: a "latest" release without `appcast.xml` makes
   every update check fail.

   Then check what GitHub serves, by hand, from the repository root:

   ```sh
   sh scripts/check-published.sh
   ```

   It downloads the published `appcast.xml` and `UploadTheFile.dmg` and compares them with
   `build/release/appcast.xml` and the SHA-256 in `build/release/UploadTheFile.dmg.sha256`. On a
   "MISMATCH", fix the release before anyone updates.

4. Homebrew: update `Casks/upload-the-file.rb` in the `Smile-Mask-Technology/homebrew-tap`
   repository with the new `version` and `sha256` (the template is
   `packaging/homebrew/upload-the-file.rb` here), then check it on a clean Mac:
   `brew install --cask smile-mask-technology/tap/upload-the-file`.

   `auto_updates true` (in the template) tells Homebrew that the app updates itself, and then
   `brew upgrade` skips the cask. Homebrew decides with the cask of the *newest* version, so people
   who installed a version without the updater would never be upgraded to the first one that has
   it. Publish the cask for the first release that contains the updater **without** the
   `auto_updates true` line, and add it in the cask of the release after that.
5. SourceForge mirrors the GitHub release.

## What the release proves before anything is published

`scripts/release.sh` stops at the first failure: tests, tree and build checks, the build number's
history, the update key and the framework's signature,
notarization (Apple's
verdict must be "Accepted"), stapling, `spctl --assess` on both the app and the DMG
(`source=Notarized Developer ID`), and the update signatures of the DMG and the appcast.
`scripts/check-published.sh` then checks what GitHub serves.

Copies installed before the first release that contains Sparkle have no updater: those people
download that release once by hand, and update themselves from then on.
