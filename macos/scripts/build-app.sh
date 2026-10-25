#!/usr/bin/env bash
# Builds RemoteSSH.app (release) into ./dist. Works with Command Line Tools only (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

# The macOS 27 SDK turns SwiftUI's @State into a macro whose plugin ships only with Xcode.
# With Command Line Tools we build against the newest 26.x SDK instead.
if [ -z "${SDKROOT:-}" ] && ! xcode-select -p | grep -q Xcode.app; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$SDK" ] && export SDKROOT="$SDK"
fi

swift build -c release --product RemoteSSH
BIN=$(swift build -c release --show-bin-path)/RemoteSSH
# VERSION may be passed in (the release workflow uses the tag); otherwise the nearest vX.Y.Z tag is used.
VERSION=${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo "1.0.0")}
VERSION=${VERSION#v}

APP=dist/RemoteSSH.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RemoteSSH"

ICONSET=$(mktemp -d)/RemoteSSH.iconset
mkdir -p "$ICONSET"
cp ../assets/icon.png "$ICONSET/base.png"  # regenerate with ../scripts/make-icon.swift
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/RemoteSSH.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>RemoteSSH</string>
  <key>CFBundleDisplayName</key><string>RemoteSSH</string>
  <key>CFBundleIdentifier</key><string>app.remotessh.RemoteSSH</string>
  <key>CFBundleExecutable</key><string>RemoteSSH</string>
  <key>CFBundleIconFile</key><string>RemoteSSH</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>RemoteSSH</string>
</dict>
</plist>
PLIST

# SIGN_IDENTITY (a "Developer ID Application: …" certificate in the keychain) signs for distribution, with the
# hardened runtime and a secure timestamp that notarization requires. Without it, an ad-hoc signature keeps
# Gatekeeper/Keychain consistent on this Mac.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
