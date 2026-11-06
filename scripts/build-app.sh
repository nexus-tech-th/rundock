#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARIZE="${NOTARIZE:-0}"
RELEASE_REPOSITORY="${RUNDOCK_RELEASE_REPOSITORY:-nexus-tech-th/rundock}"
if [[ -n "$RELEASE_REPOSITORY" && ! "$RELEASE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "RUNDOCK_RELEASE_REPOSITORY must be owner/repository" >&2; exit 2
fi
UPDATE_FEED=""
if [[ -n "$RELEASE_REPOSITORY" ]]; then
  UPDATE_FEED="<key>RunDockUpdateRepository</key><string>$RELEASE_REPOSITORY</string>"
fi

usage() {
  cat <<'EOF'
Usage: scripts/build-app.sh [--skip-build] [--identity IDENTITY] [--notarize]

Builds dist/RunDock.app and its companion CLI. --skip-build uses existing
.build/<architecture>-apple-macosx/release binaries (or .build/release).
Signing defaults to ad hoc. For notarization, provide
DEVELOPER_ID_APPLICATION, NOTARY_PROFILE (a stored notarytool profile), and
NOTARIZE=1 or pass --notarize.
EOF
}

SKIP_BUILD=0
while (($#)); do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --identity) shift; IDENTITY="${1:?missing signing identity}" ;;
    --notarize) NOTARIZE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$SKIP_BUILD" == 0 ]]; then
  (cd "$ROOT" && swift build --build-system native -c "$CONFIGURATION")
fi

ARCH="$(uname -m)"
BIN_DIR="$ROOT/.build/$ARCH-apple-macosx/$CONFIGURATION"
if [[ ! -d "$BIN_DIR" && -d "$ROOT/.build/$CONFIGURATION" ]]; then
  # Compatibility with SwiftPM layouts that use a non-triple build directory.
  BIN_DIR="$ROOT/.build/$CONFIGURATION"
fi

APP="$ROOT/dist/RunDock.app"
MACOS="$APP/Contents/MacOS"
HELPERS="$APP/Contents/Helpers"
RESOURCES="$APP/Contents/Resources"
rm -rf "$APP"
mkdir -p "$MACOS" "$HELPERS" "$RESOURCES/skills/rundock" "$RESOURCES/acknowledgments"
mkdir -p "$RESOURCES/ai-icons"
cp "$ROOT"/packaging/ai-icons/*.png "$RESOURCES/ai-icons/"
cp "$ROOT/packaging/ai-icons/README.md" "$RESOURCES/acknowledgments/AI-Icons.md"
for name in ProcessesApp processes; do
  [[ -x "$BIN_DIR/$name" ]] || { echo "Missing executable: $BIN_DIR/$name (build first or omit --skip-build)" >&2; exit 1; }
done
cp "$BIN_DIR/ProcessesApp" "$MACOS/RunDock"
cp "$BIN_DIR/processes" "$HELPERS/rundock"
cp "$ROOT/skills/rundock/SKILL.md" "$RESOURCES/skills/rundock/SKILL.md"
mkdir -p "$ROOT/dist"
ICONSET="$ROOT/dist/RunDock.iconset"
rm -rf "$ICONSET"
ICON_SOURCE="$ROOT/packaging/RunDock-icon.png"
[[ -f "$ICON_SOURCE" ]] || { echo "Missing app icon source: $ICON_SOURCE" >&2; exit 1; }
mkdir -p "$ICONSET"
for spec in "16 16" "16 32@2x" "32 32" "32 64@2x" "128 128" "128 256@2x" "256 256" "256 512@2x" "512 512" "512 1024@2x"; do
  read -r base representation <<< "$spec"
  suffix=""
  if [[ "$representation" == *@2x ]]; then
    suffix="@2x"
    pixels="${representation%@2x}"
  else
    pixels="$representation"
  fi
  sips -z "$pixels" "$pixels" "$ICON_SOURCE" --out "$ICONSET/icon_${base}x${base}${suffix}.png" >/dev/null
done
iconutil --convert icns --output "$RESOURCES/RunDock.icns" "$ICONSET"
rm -rf "$ICONSET"
cp "$ROOT/LICENSE" "$RESOURCES/acknowledgments/RunDock-LICENSE"
cat > "$RESOURCES/acknowledgments/SwiftTerm.txt" <<'EOF'
SwiftTerm
Source: https://github.com/migueldeicaza/SwiftTerm
License: MIT
EOF
SWIFTERM_LICENSE="$ROOT/.build/checkouts/SwiftTerm/LICENSE"
[[ -f "$SWIFTERM_LICENSE" ]] || { echo "SwiftTerm license missing at $SWIFTERM_LICENSE" >&2; exit 1; }
cp "$SWIFTERM_LICENSE" "$RESOURCES/acknowledgments/SwiftTerm-LICENSE"

# SwiftPM places generated resource bundles beside the executable. Preserve
# any such bundles so package resource lookups continue to work in the app.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$RESOURCES/"
done

VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION" >&2; exit 1; }
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>RunDock</string>
<key>CFBundleIconFile</key><string>RunDock.icns</string>
<key>CFBundleIdentifier</key><string>com.nexus.rundock</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>RunDock</string>
<key>CFBundleDisplayName</key><string>RunDock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
$UPDATE_FEED
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 NEXUS TECHNOLOGY COMPANY LIMITED and contributors</string>
<key>NSDocumentsFolderUsageDescription</key><string>RunDock runs development commands in the project folders you select.</string>
<key>NSDesktopFolderUsageDescription</key><string>RunDock runs development commands in the project folders you select.</string>
<key>NSDownloadsFolderUsageDescription</key><string>RunDock runs development commands in the project folders you select.</string>
</dict></plist>
EOF

if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --deep --sign "$IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

if [[ "$NOTARIZE" == 1 ]]; then
  [[ -n "$IDENTITY" ]] || { echo "Notarization requires Developer ID signing." >&2; exit 1; }
  [[ -n "${NOTARY_PROFILE:-}" ]] || { echo "Set NOTARY_PROFILE to a stored notarytool profile." >&2; exit 1; }
  ZIP="$ROOT/dist/Nexus-RunDock-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi
echo "Built $APP"
