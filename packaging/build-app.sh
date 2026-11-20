#!/bin/bash
# build-app.sh [--dmg] - assembles Tessera.app: the app, Tessera's Steam library, the compatibility tool and the Windows runtime.
#
# Builds outside the iCloud-synced Desktop (iCloud re-tags files while they are being signed). Output:
#   ~/.tessera/build/app/Tessera.app
# Signing: ad hoc. Our own binaries are signed one by one and the bundle is sealed without --deep, so Apple's
# D3DMetal inside the runtime keeps Apple's signature (re-signing it makes macOS reject it for every game).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${TESSERA_BUILD:-$HOME/.tessera/build}
RUNTIME=${TESSERA_RUNTIME:-$B/rt/out/Runtime}            # runtime/assemble.sh
OUT=$B/app
APP=$OUT/Tessera.app
VERSION=${TESSERA_VERSION:-$(cat "$ROOT/VERSION")}       # major.minor.fix, no leading zeros: x.0.0 a big update, 0.x.0 improvements once no known bugs are left, 0.0.x bug fixes and optimisation

echo "== app binary"
(cd "$ROOT/app" && swift build -c release --arch arm64 2>&1 | grep -E "error|warning: |Build complete" || true)
BIN="$(cd "$ROOT/app" && swift build -c release --arch arm64 --show-bin-path)/Tessera"
[ -x "$BIN" ] || { echo "app binary missing"; exit 1; }

echo "== Steam library and compatibility tool"
(cd "$ROOT/steampatch/src" && clang -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -O2 -Wall -dynamiclib \
    -framework Foundation -framework AppKit -o ../build/tessera_steam.dylib tessera_steam.c hook.c activation.m)
(cd "$ROOT/tool" && mkdir -p build \
    && swiftc -O -target arm64-apple-macos12.0 -o build/run-arm64 Sources/tessera-run/*.swift \
    && swiftc -O -target x86_64-apple-macos12.0 -o build/run-x86_64 Sources/tessera-run/*.swift \
    && lipo -create build/run-arm64 build/run-x86_64 -output build/run)

echo "== bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/steam" "$APP/Contents/Resources/compat/tessera"
cp "$BIN" "$APP/Contents/MacOS/Tessera"
cp "$ROOT/steampatch/build/tessera_steam.dylib" "$APP/Contents/Resources/steam/"
cp "$ROOT/tool/build/run" "$APP/Contents/Resources/compat/tessera/run"
# The internal name contains "proton": only then does Steam map Windows save folders (Saved Games, Documents, AppData)
# into the game's prefix for Steam Cloud. Steam shows display_name. SteamSetup.toolName must match.
cat > "$APP/Contents/Resources/compat/tessera/compatibilitytool.vdf" <<'EOF'
"compatibilitytools"
{
  "compat_tools"
  {
    "tessera_proton"
    {
      "install_path" "."
      "display_name" "Tessera"
      "from_oslist" "windows"
      "to_oslist" "macos"
    }
  }
}
EOF
cat > "$APP/Contents/Resources/compat/tessera/toolmanifest.vdf" <<'EOF'
"manifest"
{
  "version" "2"
  "commandline" "/run %verb%"
}
EOF
ICON="$ROOT/packaging/Tessera.icns"
[ -f "$ICON" ] || cp /Applications/Tessera.app/Contents/Resources/Tessera.icns "$ICON"
cp "$ICON" "$APP/Contents/Resources/Tessera.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Tessera</string>
    <key>CFBundleDisplayName</key><string>Tessera</string>
    <key>CFBundleIdentifier</key><string>com.polermo.tessera2</string>
    <key>CFBundleExecutable</key><string>Tessera</string>
    <key>CFBundleIconFile</key><string>Tessera</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Tessera. Windows runtime: Wine (LGPL 2.1), see Licenses.</string>
</dict>
</plist>
EOF

echo "== Windows runtime (APFS clone)"
[ -x "$RUNTIME/bin/wine" ] || { echo "no runtime at $RUNTIME (run runtime/assemble.sh)"; exit 1; }
cp -cR "$RUNTIME" "$APP/Contents/Resources/Runtime"
du -sh "$APP/Contents/Resources/Runtime" | cut -f1

echo "== licences"
"$ROOT/packaging/collect-licenses.sh" "$APP/Contents/Resources/Licenses" | sed 's/^/   files: /'

echo "== strip"
# debug maps name the object files of the build folder; nothing at run time needs them
strip -S "$APP/Contents/MacOS/Tessera" "$APP/Contents/Resources/compat/tessera/run" "$APP/Contents/Resources/steam/tessera_steam.dylib"

echo "== signing"
codesign --force --sign - "$APP/Contents/Resources/steam/tessera_steam.dylib"
codesign --force --sign - "$APP/Contents/Resources/compat/tessera/run"
codesign --force --sign - "$APP" 2>&1 | grep -v "replacing existing" || true
codesign --verify "$APP" && echo "signature ok"

if [ "${1:-}" = "--dmg" ]; then
    echo "== disk image"
    DIST=${TESSERA_DIST:-$ROOT/dist}
    STAGE=$OUT/dmg
    rm -rf "$STAGE" && mkdir -p "$STAGE" "$DIST"
    cp -cR "$APP" "$STAGE/Tessera.app"
    ln -s /Applications "$STAGE/Applications"
    cat > "$STAGE/Read Me.txt" <<'TXT'
Tessera - play your Windows Steam games on this Mac

1. Drag Tessera into Applications.
2. Open it from Applications. The first time, macOS says it cannot check Tessera for malware
   (it is free and not registered with Apple): open System Settings > Privacy & Security,
   scroll down and click "Open Anyway".
3. Click "Set up in Steam". If macOS asks, allow Tessera under Privacy & Security > App Management.
4. Steam opens again. Install and play your Windows games like any other game.

To remove: open Tessera, click "Remove from Steam...", then move Tessera to the Bin.
TXT
    rm -f "$DIST/Tessera.dmg"
    hdiutil create -volname "Tessera" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DIST/Tessera.dmg" >/dev/null
    rm -rf "$STAGE"
    du -h "$DIST/Tessera.dmg" | cut -f1 | sed "s|^|   $DIST/Tessera.dmg: |"
fi
echo "== $APP"
