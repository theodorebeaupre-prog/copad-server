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

echo "› compiling (universal)"
# Build both slices so the app runs natively on Apple Silicon AND Intel.
# Falls back to a native-only build if cross-compiling isn't available.
BIN="$BUILD/$APP_SAFE/Contents/MacOS/CoPadServer"
if swiftc -O -target arm64-apple-macos13  -o "$BUILD/CoPadServer-arm64"  main.swift -framework AppKit 2>/dev/null \
&& swiftc -O -target x86_64-apple-macos13 -o "$BUILD/CoPadServer-x86_64" main.swift -framework AppKit 2>/dev/null; then
  lipo -create "$BUILD/CoPadServer-arm64" "$BUILD/CoPadServer-x86_64" -output "$BIN"
  rm -f "$BUILD/CoPadServer-arm64" "$BUILD/CoPadServer-x86_64"
else
  echo "  (universal build unavailable — building native arch only)"
  swiftc -O -o "$BIN" main.swift -framework AppKit
fi

echo "› bundling"
cp Info.plist "$BUILD/$APP_SAFE/Contents/Info.plist"
cp AppIcon.icns "$BUILD/$APP_SAFE/Contents/Resources/" 2>/dev/null || \
  echo "  (AppIcon.icns missing — run: swift make-icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns)"

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
