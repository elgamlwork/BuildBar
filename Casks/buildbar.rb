cask "buildbar" do
  version "0.1.1"
  sha256 :no_check

  url "https://github.com/elgamlwork/BuildBar/releases/download/v#{version}/BuildBar-#{version}.dmg"
  name "BuildBar"
  desc "Menu bar dashboard for EAS Builds, Vercel deployments, and GitHub Actions"
  homepage "https://github.com/elgamlwork/BuildBar"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "BuildBar.app"

  zap trash: [
    "~/Library/Application Support/BuildBar",
    "~/Library/Caches/app.buildbar",
    "~/Library/Preferences/app.buildbar.plist",
  ]

  caveats <<~EOS
    BuildBar is not code-signed or notarized. On first launch macOS will block it.
    To open it:
      1. Open Finder and locate BuildBar in Applications.
      2. Right-click (or Control-click) BuildBar and choose "Open".
      3. Click "Open" in the dialog.
    You only have to do this once.
  EOS
end
