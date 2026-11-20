#!/bin/bash
# assemble.sh - puts together the Windows runtime that Tessera.app carries (Contents/Resources/Runtime).
#
#   Wine            $RT/wine-stage/opt/tessera      (build-wine.sh)
#   libraries       $RT/deps                        (build-deps.sh: FreeType, GnuTLS, Nettle, GMP) + MoltenVK
#   D3DMetal        Apple's Game Porting Toolkit redistributable, copied unmodified with Apple's signature
#   DXMT            the official release            (DirectX 11 -> Metal, the alternative to D3DMetal)
#   DXVK            build-dxvk.sh                   (CodeWeavers' DXVK, Direct3D 9-11 -> Vulkan, with its own MoltenVK)
#   Steam bridge    bridge/build-bridge.sh output   (lets Windows games talk to the Mac Steam client)
#
# Layout of the result:
#   bin/wine, bin/wineserver, bin/wineloader -> wine
#   lib/wine/{x86_64-windows,i386-windows,x86_64-unix}   Wine; d3d10/11/12/dxgi are Apple's D3DMetal (the default)
#   lib/wined3d/x86_64-windows                            Wine's own d3d10/11/12/dxgi (TESSERA_BACKEND_DIR)
#   lib/dxmt/...                                          DXMT (TESSERA_BACKEND_DIR)
#   lib/dxvk/{x86_64-windows,i386-windows}                DXVK + Wine's dxgi (TESSERA_BACKEND_DIR)
#   lib64/dxvk/libMoltenVK.dylib                          the MoltenVK DXVK is made for (Wine loads it via TESSERA_LIBVULKAN)
#   lib/tessera-steam/...                                 the Steam bridge (WINEDLLPATH)
#   lib64/*.dylib, lib64/apple_gptk/{external,wine}       libraries and D3DMetal
#   share/wine                                            wine.inf, NLS tables, fonts
#   share/wine/mono/wine-mono-<version>                   Wine Mono (.NET Framework programs)
#   share/wine/gecko/wine-gecko-<version>-<arch>          Wine Gecko (Internet Explorer engine)
#   lib/tessera-redist/{x86_64,i386}/OpenAL32.dll         OpenAL Soft (build-openal.sh), copied into Windows folders
set -euo pipefail
RT=${TESSERA_RT:-$HOME/.tessera/build/rt}
WINE=$RT/wine-stage/opt/tessera
DEPS=$RT/deps
GPTK=${TESSERA_GPTK:-$HOME/.tessera/Runtimes/wine-11.0-tessera-20260907/lib64/apple_gptk}
DXMT=${TESSERA_DXMT:-$RT/dxmt/v0.80}
DXVK=${TESSERA_DXVK:-$RT/deps/dxvk}
BRIDGE=${TESSERA_BRIDGE:-$HOME/.tessera/build/bridge/out}
MINGW=$HOME/.tessera/build/llvm-mingw-20261117-ucrt-macos-universal
OUT=${1:-$RT/out/Runtime}
step() { echo "== $1"; }

for need in "$WINE/bin/wine" "$WINE/bin/winebuild" "$DEPS/lib/libgnutls.30.dylib" "$GPTK/external/libd3dshared.dylib" \
            "$DXMT/x86_64-windows/d3d11.dll" "$BRIDGE/x86_64-unix/lsteamclient.so" "$BRIDGE/i386-windows/steam.exe" \
            "$DXVK/x86_64-windows/d3d11.dll" "$DXVK/i386-windows/d3d11.dll" "$DXVK/libMoltenVK.dylib"; do
    [ -e "$need" ] || { echo "missing: $need"; exit 1; }
done
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/lib64" "$OUT/share"

step "Wine"
cp "$WINE/bin/wine" "$WINE/bin/wineserver" "$OUT/bin/"
ln -s wine "$OUT/bin/wineloader"
ditto "$WINE/lib/wine" "$OUT/lib/wine"
ditto "$WINE/share/wine" "$OUT/share/wine"
find "$OUT/lib/wine" -name "*.a" -delete                      # import libraries are for building, not running

step "Wine Mono"
# .NET Framework programs (game launchers, tools) run on Wine Mono: the version this Wine asks for (mscoree's
# WINE_MONO_VERSION), unpacked where Wine looks for it (share/wine/mono/wine-mono-<version>), so Wine never offers to
# download it. The download is checked against its known SHA-256.
MONO_VERSION=$(sed -n 's/^#define WINE_MONO_VERSION "\(.*\)"/\1/p' "$RT/src/wine/dlls/mscoree/mscoree_private.h")
MONO_SHA256=a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb    # wine-mono-10.4.1-x86.tar.xz
[ "$MONO_VERSION" = 10.4.1 ] || { echo "Wine expects Wine Mono $MONO_VERSION: update MONO_SHA256"; exit 1; }
MONO_TAR=$HOME/.tessera/build/downloads/wine-mono-$MONO_VERSION-x86.tar.xz
[ -f "$MONO_TAR" ] || curl -fL --retry 3 -o "$MONO_TAR" "https://dl.winehq.org/wine/wine-mono/$MONO_VERSION/wine-mono-$MONO_VERSION-x86.tar.xz"
[ "$(shasum -a 256 "$MONO_TAR" | cut -d' ' -f1)" = "$MONO_SHA256" ] || { echo "Wine Mono download does not match"; exit 1; }
mkdir -p "$OUT/share/wine/mono"
tar -C "$OUT/share/wine/mono" -xJf "$MONO_TAR"

step "Wine Gecko"
# Wine's Internet Explorer engine (mshtml): game launchers and installers that show web pages, news or licence texts
# in an embedded browser. Unpacked where Wine looks for a shared copy (share/wine/gecko/wine-gecko-<version>-<arch>),
# so no Windows folder needs its own copy and Wine never offers to download it. Downloads checked by SHA-256.
GECKO_VERSION=$(sed -n 's/^#define GECKO_VERSION "\(.*\)"/\1/p' "$RT/src/wine/dlls/appwiz.cpl/addons.c")
[ "$GECKO_VERSION" = 2.47.4 ] || { echo "Wine expects Wine Gecko $GECKO_VERSION: update the Gecko checksums"; exit 1; }
mkdir -p "$OUT/share/wine/gecko"
for arch_sum in x86:2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6 \
                x86_64:fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814; do
    arch=${arch_sum%%:*}
    tarball=$HOME/.tessera/build/downloads/redist/wine-gecko-$GECKO_VERSION-$arch.tar.xz
    [ -f "$tarball" ] || curl -fL --retry 3 -o "$tarball" "https://dl.winehq.org/wine/wine-gecko/$GECKO_VERSION/wine-gecko-$GECKO_VERSION-$arch.tar.xz"
    [ "$(shasum -a 256 "$tarball" | cut -d' ' -f1)" = "${arch_sum#*:}" ] || { echo "Wine Gecko ($arch) download does not match"; exit 1; }
    tar -C "$OUT/share/wine/gecko" -xJf "$tarball"
done

step "OpenAL Soft"
# build-openal.sh: OpenAL32.dll for 64- and 32-bit games; the launcher copies them into each Windows folder
[ -f "$RT/openal/x86_64/OpenAL32.dll" ] && [ -f "$RT/openal/i386/OpenAL32.dll" ] || { echo "run build-openal.sh first"; exit 1; }
mkdir -p "$OUT/lib/tessera-redist"
ditto "$RT/openal/x86_64" "$OUT/lib/tessera-redist/x86_64"
ditto "$RT/openal/i386" "$OUT/lib/tessera-redist/i386"

step "debug info"
# Left in, Wine's own dbghelp trips over it and kills the process that touched it (Steam's helpers, every time)
find "$OUT/lib/wine/x86_64-windows" "$OUT/lib/wine/i386-windows" -type f \
     \( -name "*.dll" -o -name "*.exe" -o -name "*.drv" -o -name "*.sys" -o -name "*.acm" -o -name "*.ocx" \
        -o -name "*.cpl" -o -name "*.tlb" -o -name "*.ax" -o -name "*.ds" -o -name "*.msstyles" \) \
     -exec "$MINGW/bin/llvm-strip" --strip-debug {} + 2>/dev/null || true
find "$OUT/lib/wine/x86_64-unix" -name "*.so" -type f -exec strip -S {} + 2>/dev/null || true
strip -S "$OUT/bin/wine" "$OUT/bin/wineserver"

step "libraries"
LIBS="libfreetype.6.dylib libgnutls.30.dylib libnettle.8.dylib libhogweed.6.dylib libgmp.10.dylib libMoltenVK.dylib"
# FFmpeg: what winedmo links (avformat, avcodec, avutil) and what those need (swresample)
for ff in libavformat.61.dylib libavcodec.61.dylib libavutil.59.dylib libswresample.5.dylib; do
    [ -f "$DEPS/lib/$ff" ] && LIBS="$LIBS $ff"
done
# GStreamer (build-gstreamer.sh): its plugins go to lib64/gstreamer-1.0; the libraries that winegstreamer.so and the
# plugins link - followed link by link, so none of the unused GStreamer libraries come along - join the list above
GST_PLUGINS=$DEPS/lib/gstreamer-1.0
if [ -f "$OUT/lib/wine/x86_64-unix/winegstreamer.so" ] && [ -d "$GST_PLUGINS" ]; then
    todo="$OUT/lib/wine/x86_64-unix/winegstreamer.so $(ls "$GST_PLUGINS"/*.dylib)"
    seen=" "
    while [ -n "$todo" ]; do
        set -- $todo; f=$1; shift; todo="$*"
        for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep -E "^($DEPS|/opt/tessera-deps)/lib/[^/]+\.dylib$" || true); do
            name=$(basename "$dep")
            case "$seen" in *" $name "*) continue;; esac
            seen="$seen$name "
            todo="$todo $DEPS/lib/$name"
        done
    done
    for name in $seen; do case " $LIBS " in *" $name "*) ;; *) LIBS="$LIBS $name";; esac; done
    mkdir -p "$OUT/lib64/gstreamer-1.0"
    for plugin in "$GST_PLUGINS"/*.dylib; do
        f="$OUT/lib64/gstreamer-1.0/$(basename "$plugin")"
        cp -L "$plugin" "$f"; chmod u+w "$f"
        install_name_tool -id "@rpath/$(basename "$plugin")" "$f" 2>/dev/null
        strip -S -x "$f" 2>/dev/null || true
        for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep -E "^($DEPS|/opt/tessera-deps)/lib/" || true); do
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
        done
        install_name_tool -add_rpath @loader_path/.. "$f" 2>/dev/null || true
        codesign --force --sign - "$f" 2>/dev/null
    done
    echo "   GStreamer: $(ls "$OUT/lib64/gstreamer-1.0" | wc -l | tr -d ' ') plugins,$seen"
fi
for name in $LIBS; do
    f="$OUT/lib64/$name"
    cp -L "$DEPS/lib/$name" "$f"
    chmod u+w "$f"
    install_name_tool -id "@rpath/$name" "$f" 2>/dev/null
    strip -S -x "$f" 2>/dev/null || true                     # debug maps name the build folders
    for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep -E "^($DEPS|/opt/tessera-deps)/lib/" || true); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
    done
    install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
done

step "search paths"
# Wine's own unix libraries that link a bundled library directly (winedmo -> FFmpeg) find it through @rpath too
for so in "$OUT"/lib/wine/x86_64-unix/*.so; do
    [ -L "$so" ] && continue
    for dep in $(otool -L "$so" | awk 'NR>1 {print $1}' | grep -E "^($DEPS|/opt/tessera-deps)/lib/" || true); do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$so" 2>/dev/null
    done
done
# The binaries reference their libraries through @rpath; macOS ignores DYLD_LIBRARY_PATH for signed loaders.
for b in "$OUT/bin/wine" "$OUT/bin/wineserver"; do
    install_name_tool -add_rpath "@loader_path/../lib64" "$b" 2>/dev/null || true
done
find "$OUT/lib/wine/x86_64-unix" -name "*.so" -type f \
     -exec install_name_tool -add_rpath "@loader_path/../../../lib64" {} \; 2>/dev/null || true

step "D3DMetal (Apple, unmodified)"
mkdir -p "$OUT/lib64/apple_gptk" "$OUT/lib/wined3d/x86_64-windows"
ditto "$GPTK/external" "$OUT/lib64/apple_gptk/external"
ditto "$GPTK/wine" "$OUT/lib64/apple_gptk/wine"
W="$OUT/lib/wine/x86_64-windows"; U="$OUT/lib/wine/x86_64-unix"
# d3d12core: D3DMetal 4 brings its own (its d3d12.dll loads it); Wine's goes to the WineD3D folder then
for d in d3d10 d3d11 d3d12 d3d12core dxgi; do
    [ -f "$GPTK/wine/x86_64-windows/$d.dll" ] || continue
    [ -f "$W/$d.dll" ] && mv "$W/$d.dll" "$OUT/lib/wined3d/x86_64-windows/$d.dll"
    cp "$GPTK/wine/x86_64-windows/$d.dll" "$W/$d.dll"
    ln -sf "../../../lib64/apple_gptk/external/libd3dshared.dylib" "$U/$d.so"
done
# Apple's copies of those DLLs now sit in Wine's folders and the .so links point at libd3dshared directly; the rest of
# Apple's wine/ folder (AMD and NVIDIA stand-ins) is not used
rm -rf "$OUT/lib64/apple_gptk/wine"
# NVIDIA's names stay out of the default path: Chromium-based launchers probe nvapi64 at start and stall on it
rm -f "$W/nvapi64.dll" "$W/nvngx.dll" "$U/nvapi64.so" "$U/nvngx.so"

step "DXMT"
mkdir -p "$OUT/lib/dxmt"
for arch in x86_64-windows i386-windows x86_64-unix; do ditto "$DXMT/$arch" "$OUT/lib/dxmt/$arch"; done
# DXMT's NVIDIA stand-ins never load here (Tessera gives them no system-folder placeholder, see the launcher)
rm -f "$OUT/lib/dxmt/x86_64-windows/nvapi64.dll" "$OUT/lib/dxmt/x86_64-windows/nvngx.dll"
# winemetal.so links Wine's winemac.so and ntdll.so through @rpath
for rp in "@loader_path/../../wine/x86_64-unix" "@loader_path/../../../lib64"; do
    install_name_tool -add_rpath "$rp" "$OUT/lib/dxmt/x86_64-unix/winemetal.so" 2>/dev/null || true
done

step "DXVK"
# CodeWeavers' DXVK for macOS and the MoltenVK it is made for (with the runtime's MoltenVK 1.4.2 it crashes at once);
# Wine's own dxgi goes with it, as in CrossOver: DXVK presents through it. Only games on DXVK use either.
mkdir -p "$OUT/lib/dxvk/x86_64-windows" "$OUT/lib/dxvk/i386-windows" "$OUT/lib64/dxvk"
cp "$DXVK"/x86_64-windows/*.dll "$OUT/lib/dxvk/x86_64-windows/"
cp "$DXVK"/i386-windows/*.dll "$OUT/lib/dxvk/i386-windows/"
# Wine loads a DLL from a game's backend folder (TESSERA_BACKEND_DIR) only if it is marked as a Wine builtin, and
# otherwise falls back to the default D3DMetal ones without a word; CrossOver's DXVK DLLs carry the same mark
"$WINE/bin/winebuild" --builtin "$OUT"/lib/dxvk/x86_64-windows/*.dll "$OUT"/lib/dxvk/i386-windows/*.dll
cp "$OUT/lib/wined3d/x86_64-windows/dxgi.dll" "$OUT/lib/dxvk/x86_64-windows/dxgi.dll"
cp "$OUT/lib/wine/i386-windows/dxgi.dll" "$OUT/lib/dxvk/i386-windows/dxgi.dll"
cp "$DXVK/libMoltenVK.dylib" "$OUT/lib64/dxvk/libMoltenVK.dylib"

step "Steam bridge"
SB="$OUT/lib/tessera-steam"
mkdir -p "$SB/x86_64-windows" "$SB/i386-windows" "$SB/x86_64-unix"
cp "$BRIDGE/x86_64-windows/lsteamclient.dll" "$SB/x86_64-windows/"
cp "$BRIDGE/i386-windows/lsteamclient.dll" "$SB/i386-windows/"
cp "$BRIDGE/x86_64-unix/lsteamclient.so" "$SB/x86_64-unix/"
cp "$BRIDGE/x86_64-windows/steam.exe" "$SB/x86_64-windows/steam.exe"     # Wine built-ins (bridge/build-bridge.sh)
cp "$BRIDGE/i386-windows/steam.exe" "$SB/i386-windows/steam.exe"
"$MINGW/bin/llvm-strip" --strip-debug "$SB"/*-windows/lsteamclient.dll "$SB"/*-windows/steam.exe 2>/dev/null || true
strip -S "$SB/x86_64-unix/lsteamclient.so" 2>/dev/null || true

step "signing"
# Wine writes and runs its own code: the loader gets the entitlements for that, and may load our unsigned libraries.
ENT=$(mktemp -t tessera-ent)
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
	<key>com.apple.security.cs.disable-executable-page-protection</key><true/>
	<key>com.apple.security.cs.disable-library-validation</key><true/>
	<key>com.apple.security.device.audio-input</key><true/>
	<key>com.apple.security.device.camera</key><true/>
</dict></plist>
PLIST
for b in "$OUT/bin/wine" "$OUT/bin/wineserver"; do
    codesign --force --sign - --options runtime --entitlements "$ENT" "$b" 2>&1 | grep -v "replacing existing" || true
done
rm -f "$ENT"
# our own Mach-O files only - Apple's D3DMetal keeps Apple's signature (re-signing it makes macOS reject it)
find "$OUT/lib/wine/x86_64-unix" "$OUT/lib/dxmt/x86_64-unix" "$SB/x86_64-unix" -name "*.so" -type f \
     -exec codesign --force --sign - {} \; 2>/dev/null
find "$OUT/lib64" -maxdepth 1 -name "*.dylib" -type f -exec codesign --force --sign - {} \; 2>/dev/null
codesign --force --sign - "$OUT/lib64/dxvk/libMoltenVK.dylib"
xattr -cr "$OUT" 2>/dev/null || true
codesign -v "$OUT/lib64/apple_gptk/external/libd3dshared.dylib" && echo "   D3DMetal keeps Apple's signature"

step "description"
cat > "$OUT/tessera-runtime.json" <<EOF
{
  "name": "Tessera Windows runtime",
  "built": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "wine": "$("$OUT/bin/wine" --version 2>/dev/null || echo wine-11.0)",
  "components": {
    "D3DMetal": "Apple Game Porting Toolkit redistributable (unmodified)",
    "DXMT": "$(basename "$DXMT")",
    "MoltenVK": "1.4.2",
    "DXVK": "1.10.3 for macOS (built from source)",
    "MoltenVK for DXVK": "1.2.10 (built from source)",
    "FreeType": "$(sed -n 's/^#define FREETYPE_MAJOR *//p;s/^#define FREETYPE_MINOR *//p;s/^#define FREETYPE_PATCH *//p' "$DEPS/include/freetype2/freetype/freetype.h" | paste -sd. -)",
    "GnuTLS": "$(sed -n 's/^#define GNUTLS_VERSION "\(.*\)"/\1/p' "$DEPS/include/gnutls/gnutls.h")",
    "FFmpeg": "$([ -f "$DEPS/lib/libavcodec.61.dylib" ] && echo 7.1.1 || echo none)"
  },
  "graphics": ["d3dmetal", "dxmt", "dxvk", "wined3d"]
}
EOF

step "check"
# /Users/runner/... in DXMT is its GitHub build server, not this Mac
leaks=$(grep -rl -a -E "$HOME|/Users/[a-z]" "$OUT" 2>/dev/null | grep -v "/apple_gptk/" \
        | while read -r f; do strings -a "$f" | grep -E "$HOME|/Users/[a-z]" | grep -v "/Users/runner/" | grep -q . && echo "$f"; done | head -5 || true)
[ -z "$leaks" ] && echo "   no build-machine paths" || { echo "   build-machine paths in:"; echo "$leaks" | sed 's/^/     /'; }
# brand names only; skipped: FFmpeg ("crossover" is an audio term there), fonts (they credit their designers), Wine
# Mono (its libraries credit their authors), CodeWeavers' DXVK and MoltenVK (theirs, credited as such), and
# copyright lines inside embedded scripts - credits and copyright notices must stay
brand=$(grep -rl -a -E "CrossOver|Crossover|CROSSOVER|CodeWeavers|Codeweavers|codeweavers" "$OUT" 2>/dev/null \
        | grep -v -E "/apple_gptk/|/lib64/libav|/share/wine/fonts/|/share/wine/mono/|/lib/dxvk/|/lib64/dxvk/" | while read -r f; do
            strings -a "$f" | grep -E "CrossOver|Crossover|CROSSOVER|CodeWeavers|Codeweavers|codeweavers" \
                | grep -v -i -E "copyright|\(c\)" | grep -q . && echo "$f"; done | head -8 || true)
[ -z "$brand" ] && echo "   no CrossOver/CodeWeavers text" || { echo "   CrossOver/CodeWeavers text in:"; echo "$brand" | sed 's/^/     /'; }
du -sh "$OUT" | cut -f1
