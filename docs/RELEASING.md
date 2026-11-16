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
  the private half, and installed copies refuse an update that is not. Check:
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account uploadthefile-mac -p` prints the
  public key (it never prints the private one). **Keep a backup** of the key in a password
  manager (`generate_keys --account uploadthefile-mac -x <file>` writes it to a file; store it,
  then delete the file; `-f <file>` imports it on another Mac): if it is lost, copies already installed cannot be
  updated automatically any more, and people must download the app again. Never put it in the
  repository, in CI, or in a chat.

## Each release

1. Set the version in `VERSION` (it must equal `UptfKitVersion.value`; a test checks it), commit.
   Write the release notes as an HTML file (a few `<h2>`, `<ul>` and `<p>`; Sparkle shows it in the
   update window).
2. Build, sign, notarize, staple and package:

   ```sh
   SIGN_IDENTITY="Developer ID Application: Smile Mask Technology FZE (G323SXP8VG)" \
   NOTARY_PROFILE=uptf-notary RELEASE_NOTES_HTML=release-notes.html scripts/release.sh
   ```

   It refuses to start without `RELEASE_NOTES_HTML`. It refuses a tree that differs from the
   commit (modified files, and files git does not know in
   `Sources`, `Resources`, `scripts`, `Package.swift`, `Package.resolved`, `VERSION`), runs the tests
   (which must report at least `scripts/min-test-count` of them), checks that the keychain holds the
   update signing key, builds a universal app (Apple silicon and Intel) with exactly the package
   versions in `Package.resolved`, and checks the tree again after the build. It then checks the app:
   both programs hold both architectures, the signature verifies
   (`codesign --verify --strict --deep`) with the hardened runtime and no entitlements, the bundle's
   version and `uptf --version` equal `VERSION`, and the app contains no snapshot code. For the
   updater it also checks that the app's `SUPublicEDKey` equals the keychain's public key, and that
   `Sparkle.framework` (with its `Autoupdate` and `Updater.app`) is signed by the same team as the
   app with the hardened runtime and has no `XPCServices`. After that it has Apple notarize the app and
   then the DMG, staples both, checks Gatekeeper, signs the finished DMG for Sparkle
   (`sign_update`, verified straight away) and writes
   `build/release/UploadTheFile.dmg`, its `.sha256` and `build/release/appcast.xml` (one item: the
   version, the build number Sparkle compares, minimum macOS 14, the DMG's address, its signature and
   size, and the release notes). The DMG name never changes, so the
   README's download link (`releases/latest/download/UploadTheFile.dmg`) always serves the newest
   release; never rename the asset. The build number is the commit count, so a new release always
   compares as newer than the one before.
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
   and is not offered.

4. Homebrew: update `Casks/upload-the-file.rb` in the `Smile-Mask-Technology/homebrew-tap`
   repository with the new `version` and `sha256` (the template is
   `packaging/homebrew/upload-the-file.rb` here), then check it on a clean Mac:
   `brew install --cask smile-mask-technology/tap/upload-the-file`.
5. SourceForge mirrors the GitHub release.

## What the release proves before anything is published

`scripts/release.sh` stops at the first failure: tests, tree and build checks, the update key and the
framework's signature, signature,
notarization (Apple's
verdict must be "Accepted"), stapling, `spctl --assess` on both the app and the DMG
(`source=Notarized Developer ID`), and the update signature of the DMG.

Copies installed before the first release that contains Sparkle have no updater: those people
download that release once by hand, and update themselves from then on.
