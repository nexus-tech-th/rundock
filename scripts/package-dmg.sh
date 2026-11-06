#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_BUILD=0
BUILD_ARGS=()
while (($#)); do
  case "$1" in
    --skip-build) SKIP_BUILD=1; BUILD_ARGS+=(--skip-build) ;;
    --identity) BUILD_ARGS+=(--identity "${2:?missing identity}"); shift ;;
    --notarize) BUILD_ARGS+=(--notarize) ;;
    -h|--help) echo "Usage: scripts/package-dmg.sh [--skip-build] [--identity IDENTITY] [--notarize]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

"$ROOT/scripts/build-app.sh" "${BUILD_ARGS[@]}"
APP="$ROOT/dist/RunDock.app"
[[ -d "$APP" ]] || { echo "App bundle missing: $APP" >&2; exit 1; }
ARCH="$(uname -m)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION" >&2; exit 1; }
OUT="$ROOT/dist/RunDock-$VERSION-$ARCH.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/rundock-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/RunDock.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
hdiutil create -volname "RunDock" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
(cd "$ROOT/dist" && shasum -a 256 "$(basename "$OUT")") > "$OUT.sha256"
echo "Created $OUT"
echo "SHA-256: $(awk '{print $1}' "$OUT.sha256")"
