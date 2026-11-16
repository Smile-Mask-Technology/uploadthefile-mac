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

## Each release

1. Set the version in `VERSION` (it must equal `UptfKitVersion.value`; a test checks it), commit.
2. Build, sign, notarize, staple and package:

   ```sh
   SIGN_IDENTITY="Developer ID Application: Smile Mask Technology FZE (G323SXP8VG)" \
   NOTARY_PROFILE=uptf-notary scripts/release.sh
   ```

   It refuses a tree that differs from the commit (modified files, and files git does not know in
   `Sources`, `Resources`, `scripts`, `Package.swift`, `Package.resolved`, `VERSION`), runs the tests
   (which must report at least `scripts/min-test-count` of them), builds a universal app (Apple
   silicon and Intel) with exactly the package versions in `Package.resolved`, and checks the tree
   again after the build. It then checks the app: both programs hold both architectures, the
   signature verifies (`codesign --verify --strict --deep`) with the hardened runtime and no
   entitlements, the bundle's version and `uptf --version` equal `VERSION`, and the app contains no
   snapshot code. After that it has Apple notarize the app and then the DMG, staples both, checks
   Gatekeeper, and writes
   `build/release/UploadTheFile.dmg` and its `.sha256`. The DMG name never changes, so the
   README's download link (`releases/latest/download/UploadTheFile.dmg`) always serves the newest
   release; never rename the asset.
3. Tag and publish on GitHub:

   ```sh
   git tag -s v<version> -m "Upload the File <version>"
   git push origin main v<version>
   gh release create v<version> build/release/UploadTheFile.dmg \
     build/release/UploadTheFile.dmg.sha256 --title "Upload the File <version>" --notes-file <notes.md>
   ```

4. Homebrew: update `Casks/upload-the-file.rb` in the `Smile-Mask-Technology/homebrew-tap`
   repository with the new `version` and `sha256` (the template is
   `packaging/homebrew/upload-the-file.rb` here), then check it on a clean Mac:
   `brew install --cask smile-mask-technology/tap/upload-the-file`.
5. SourceForge mirrors the GitHub release.

## What the release proves before anything is published

`scripts/release.sh` stops at the first failure: tests, tree and build checks, signature,
notarization (Apple's
verdict must be "Accepted"), stapling, and `spctl --assess` on both the app and the DMG
(`source=Notarized Developer ID`).
