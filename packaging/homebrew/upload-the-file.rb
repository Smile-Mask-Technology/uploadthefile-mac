# Template for Casks/upload-the-file.rb in Smile-Mask-Technology/homebrew-tap.
# Fill in version and sha256 from build/release/UploadTheFile.dmg.sha256 (see docs/RELEASING.md).
cask "upload-the-file" do
  version "0.1.1"
  sha256 "13697e175599fe9d031f3e188b94874e71315f43fa01cec0baa6b528f01cf6dc"

  url "https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/download/v#{version}/UploadTheFile.dmg"
  name "Upload the File"
  desc "Put files and folders online and get a link, from the menu bar or Finder"
  homepage "https://uploadthefile.com/"

  # The app updates itself (Sparkle); `brew upgrade` leaves such casks to the app. Homebrew decides
  # with the newest cask, so leave this line out of the cask for the first release that contains
  # the updater and add it from the release after that (docs/RELEASING.md).
  auto_updates true

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Upload the File.app"
  binary "#{appdir}/Upload the File.app/Contents/Resources/uptf"

  uninstall quit: "com.smilemasktechnology.uploadthefile"

  zap trash: [
    "~/Library/Application Support/UploadTheFile",
    "~/Library/Caches/com.smilemasktechnology.uploadthefile",
    "~/Library/HTTPStorages/com.smilemasktechnology.uploadthefile",
    "~/Library/Preferences/com.smilemasktechnology.uploadthefile.plist",
  ]
end
