#!/usr/bin/env bash
# Builds HerdrTouchBar.app — a background (LSUIElement) AppKit app that owns the
# Control Strip badge. Herdr runs this via the `build` entry in herdr-plugin.toml.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/HerdrTouchBar.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
DEPLOY_TARGET="11.0"

SOURCES=("$ROOT"/Sources/*.swift)
HEADER="$ROOT/Sources/HerdrTouchBarPrivate.h"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR/agents"

compile() {
  local arch="$1" out="$2"
  swiftc -O \
    -target "${arch}-apple-macosx${DEPLOY_TARGET}" \
    -import-objc-header "$HEADER" \
    -framework Cocoa \
    -F /System/Library/PrivateFrameworks -framework DFRFoundation \
    -o "$out" "${SOURCES[@]}"
}

# Ship a universal binary when possible: most Touch Bar Macs are Intel, but the
# M1 13" has one too, so both slices are worth having.
SLICES=()
for arch in arm64 x86_64; do
  if compile "$arch" "$BUILD/HerdrTouchBar-$arch" 2>"$BUILD/build-$arch.log"; then
    SLICES+=("$BUILD/HerdrTouchBar-$arch")
  else
    echo "note: skipping $arch slice (see build/build-$arch.log)" >&2
  fi
done

if [ ${#SLICES[@]} -eq 0 ]; then
  echo "error: no architecture built successfully" >&2
  cat "$BUILD"/build-*.log >&2
  exit 1
fi

if [ ${#SLICES[@]} -gt 1 ]; then
  lipo -create -output "$MACOS_DIR/HerdrTouchBar" "${SLICES[@]}"
else
  cp "${SLICES[0]}" "$MACOS_DIR/HerdrTouchBar"
fi
rm -f "${SLICES[@]}"

cp "$ROOT"/assets/icons/agents/*.png "$RES_DIR/agents/"

VERSION="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$ROOT/herdr-plugin.toml" | head -1)"
VERSION="${VERSION:-0.1.0}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>HerdrTouchBar</string>
  <key>CFBundleIdentifier</key><string>dev.herdr.touchbar</string>
  <key>CFBundleName</key><string>HerdrTouchBar</string>
  <key>CFBundleDisplayName</key><string>Herdr Touch Bar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>${DEPLOY_TARGET}</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for the Touch Bar private APIs, no developer account needed.
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "built $APP"
