# Template for Casks/upload-the-file.rb in Smile-Mask-Technology/homebrew-tap.
# Fill in version and sha256 from build/release/UploadTheFile.dmg.sha256 (see docs/RELEASING.md).
cask "upload-the-file" do
  version "0.1.0"
  sha256 "REPLACE_WITH_THE_DMG_SHA256"

  url "https://github.com/Smile-Mask-Technology/uploadthefile-mac/releases/download/v#{version}/UploadTheFile.dmg"
  name "Upload the File"
  desc "Put files and folders online and get a link, from the menu bar or Finder"
  homepage "https://uploadthefile.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Upload the File.app"
  binary "#{appdir}/Upload the File.app/Contents/Resources/uptf"

  uninstall quit: "com.smilemasktechnology.uploadthefile"

  zap trash: [
    "~/Library/Application Support/UploadTheFile",
    "~/Library/Preferences/com.smilemasktechnology.uploadthefile.plist",
  ]
end
