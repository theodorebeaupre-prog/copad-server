#!/bin/bash
# Build "Co/Pad Server.app" — a menu-bar app that runs the Node helper.
set -euo pipefail

cd "$(dirname "$0")"
HELPER="../mac-helper"
APP="Co/Pad Server.app"
APP_SAFE="CoPad Server.app"   # avoid "/" in the on-disk name
BUILD="build"

echo "› cleaning"
rm -rf "$BUILD"
mkdir -p "$BUILD/$APP_SAFE/Contents/MacOS" "$BUILD/$APP_SAFE/Contents/Resources"

echo "› compiling"
swiftc -O -o "$BUILD/$APP_SAFE/Contents/MacOS/CoPadServer" main.swift -framework AppKit

echo "› bundling"
cp Info.plist "$BUILD/$APP_SAFE/Contents/Info.plist"

# Ensure helper deps are present, then copy the helper into Resources.
if [ ! -d "$HELPER/node_modules" ]; then
  echo "› installing helper deps"
  ( cd "$HELPER" && npm install --silent )
fi
cp "$HELPER/server.js"        "$BUILD/$APP_SAFE/Contents/Resources/"
cp "$HELPER/package.json"     "$BUILD/$APP_SAFE/Contents/Resources/"   # marks Resources as CommonJS
cp "$HELPER/kokoro_speak.py"  "$BUILD/$APP_SAFE/Contents/Resources/" 2>/dev/null || true
cp -R "$HELPER/node_modules"  "$BUILD/$APP_SAFE/Contents/Resources/"

# Prefer a stable self-signed identity so the Accessibility grant SURVIVES
# rebuilds. Create it once (see README) and every build reuses it; otherwise
# fall back to ad-hoc (Accessibility must be re-granted after each rebuild).
# Pick the best signing identity. A trusted Apple identity (Developer ID or
# Apple Development) is what macOS TCC honors so the Accessibility grant persists
# across rebuilds. Fall back to the self-signed cert, then ad-hoc.
IDENT=""
for pat in "Developer ID Application" "Apple Development" "CoPad Self-Signed"; do
  IDENT=$(security find-identity -p codesigning 2>/dev/null | grep "$pat" | head -1 | awk '{print $2}' || true)
  [ -n "$IDENT" ] && { LABEL="$pat"; break; }
done
if [ -n "$IDENT" ]; then
  echo "› signing with $LABEL ($IDENT)"
  codesign --force --deep --sign "$IDENT" "$BUILD/$APP_SAFE" 2>&1 | grep -v "replacing" || true
else
  echo "› signing (ad-hoc — re-grant Accessibility after each rebuild)"
  codesign --force --deep --sign - "$BUILD/$APP_SAFE" >/dev/null 2>&1 || echo "  (codesign skipped)"
fi

echo "✓ built  $BUILD/$APP_SAFE"
echo "  open with:  open \"$BUILD/$APP_SAFE\""
