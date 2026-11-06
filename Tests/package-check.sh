#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
DMG="${1:-$ROOT/dist/RunDock-$VERSION-$(uname -m).dmg}"
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/rundock-mount.XXXXXX")"
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT
hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$DMG" >/dev/null
APP="$MOUNT/RunDock.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = com.nexus.rundock
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist")" = RunDock
test "$("$APP/Contents/Helpers/rundock" --version)" = "$VERSION"
test -f "$APP/Contents/Resources/RunDock.icns"
test -f "$APP/Contents/Resources/skills/rundock/SKILL.md"
test -f "$APP/Contents/Resources/acknowledgments/RunDock-LICENSE"
test -f "$APP/Contents/Resources/acknowledgments/SwiftTerm-LICENSE"
test -L "$MOUNT/Applications"
codesign --verify --deep --strict "$APP"
echo 'PASS: DMG integrity, read-only mount, bundle identity, CLI version, icon, skill, licenses, Applications link and local code signature'
