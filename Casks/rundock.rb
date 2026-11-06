cask "rundock" do
  version "0.4.1"
  sha256 "6383db8bc0d93e5522c90a0bd5088bfb93ca7a66ac3c7e63a76ee30ba6ff6420"

  url "https://github.com/nexus-tech-th/rundock/releases/download/v#{version}/RunDock-#{version}-arm64.dmg"
  name "RunDock"
  desc "Persistent terminals and shared AI process control"
  homepage "https://github.com/nexus-tech-th/rundock"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "RunDock.app"
  binary "#{appdir}/RunDock.app/Contents/Helpers/rundock"

  caveats <<~EOS
    Open RunDock and choose Connect AI to install its MCP integration.
    Connect Codex also installs the bundled routing skill.
  EOS

  # Managed worktrees may contain uncommitted code; retain application data.
end
