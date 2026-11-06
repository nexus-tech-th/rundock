#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if (($# != 1)) || [[ ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: scripts/promote-homebrew-cask.sh vVERSION" >&2
  exit 2
fi
TAG="$1"
VERSION="${TAG#v}"
REPO=nexus-tech-th/rundock
[[ "$(uname -m)" == arm64 ]] || { echo 'Run this promotion on Apple Silicon.' >&2; exit 1; }
[[ "$(tr -d '\r\n' < "$ROOT/VERSION")" == "$VERSION" ]] || { echo 'VERSION does not match tag.' >&2; exit 1; }
[[ "$(gh release view "$TAG" --repo "$REPO" --json isDraft --jq .isDraft)" == false ]] || { echo 'Release must be published first.' >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rundock-promote.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
DMG="RunDock-$VERSION-arm64.dmg"
gh release download "$TAG" --repo "$REPO" --dir "$TMP" --pattern "$DMG" --pattern "$DMG.sha256" --pattern rundock.rb
(cd "$TMP" && shasum -a 256 -c "$DMG.sha256")
SHA="$(shasum -a 256 "$TMP/$DMG" | awk '{print $1}')"
# Build in a temporary tree, leaving any current cask untouched on failure.
mkdir -p "$TMP/tree/scripts"
cp "$ROOT/scripts/generate-homebrew-cask.sh" "$TMP/tree/scripts/"
"$TMP/tree/scripts/generate-homebrew-cask.sh" nexus-tech-th rundock "$VERSION" "$SHA"
cmp -s "$TMP/rundock.rb" "$TMP/tree/Casks/rundock.rb" || { echo 'Release cask does not match the downloaded DMG.' >&2; exit 1; }
mkdir -p "$ROOT/Casks"
cp "$TMP/rundock.rb" "$ROOT/Casks/rundock.rb"
cat <<'INSTRUCTIONS'
Verified and updated Casks/rundock.rb. Review the diff, then publish the cask commit:
  git diff -- Casks/rundock.rb
  git add Casks/rundock.rb
  nexus-github-guard orbit
  nexus-github-run orbit -- git commit -m "Update Homebrew cask"
  nexus-github-run orbit -- bash -lc 'git -c http.https://github.com/.extraheader="AUTHORIZATION: bearer $GH_TOKEN" push origin HEAD'
INSTRUCTIONS
