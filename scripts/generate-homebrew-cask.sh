#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (($# != 4)); then
  echo "Usage: scripts/generate-homebrew-cask.sh GITHUB_OWNER REPOSITORY VERSION DMG_SHA256" >&2
  exit 2
fi
OWNER="$1" REPO="$2" VERSION="$3" SHA="$4"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported Homebrew release architecture: $ARCH" >&2; exit 2 ;; esac
if [[ "$ARCH" == arm64 ]]; then
  CASK_ARCH=arm64
else
  CASK_ARCH=intel
fi
[[ "$OWNER" =~ ^[A-Za-z0-9_.-]+$ && "$REPO" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "Invalid GitHub owner/repository" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { echo "Invalid version" >&2; exit 2; }
[[ "$SHA" =~ ^[A-Fa-f0-9]{64}$ ]] || { echo "DMG SHA-256 must contain 64 hex characters" >&2; exit 2; }
mkdir -p "$ROOT/Casks"
cat > "$ROOT/Casks/rundock.rb" <<EOF
cask "rundock" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$OWNER/$REPO/releases/download/v#{version}/RunDock-#{version}-$ARCH.dmg"
  name "RunDock"
  desc "Persistent terminals and shared AI process control"
  homepage "https://github.com/$OWNER/$REPO"

  depends_on macos: ">= :ventura"
  depends_on arch: :$CASK_ARCH

  app "RunDock.app"
  binary "#{appdir}/RunDock.app/Contents/Helpers/rundock"

  caveats <<~EOS
    Open RunDock and choose Connect AI to install its MCP integration.
    Connect Codex also installs the bundled routing skill.
  EOS

  zap trash: "~/Library/Application Support/RunDock"
end
EOF
echo "Generated $ROOT/Casks/rundock.rb; review the release URL and architecture before publishing the cask."
