#!/bin/bash
# package-sources.sh [OUT_DIR] - the source archive published next to every Tessera release (the runtime's LGPL
# libraries require it): the exact sources the runtime is built from, so anyone can rebuild it or swap in a
# modified library.
#
#   wine/        Wine 11.0 exactly as built: Tessera's changes (scripts/patch-wine.py) are already applied, and
#                code-comment wording is neutral. Copyright and author notices are untouched.
#   freetype/, gmp/, gnutls/, nettle-3.10.tar.gz, ffmpeg-7.1.1.tar.xz   the libraries, as released
#   gstreamer/   GStreamer and the subprojects its build fetched, as released
#   steam-bridge/  Valve's lsteamclient (from Proton) as adapted for the Mac Steam client, and steam.exe
#   scripts/     Tessera's build scripts
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
S=$HOME/.tessera/build/sources/sources
RT=${TESSERA_RT:-$HOME/.tessera/build/rt}
DL=$HOME/.tessera/build/downloads
OUT=${1:-$HERE/../dist}
NAME=tessera-runtime-src-$(date +%Y%m%d)
TMP=$(mktemp -d)
STAGE=$TMP/$NAME
mkdir -p "$STAGE/scripts" "$STAGE/steam-bridge" "$OUT"

echo "== Wine (as built)"
rsync -a --exclude ".git" "$RT/src/wine/" "$STAGE/wine/"
python3 - "$STAGE/wine" <<'EOF'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
word = re.compile(r"Cross[Oo]ver|CROSSOVER")
keep = re.compile(r"copyright|\(c\)|©", re.I)
n = 0
for p in root.rglob("*"):
    if not p.is_file() or p.stat().st_size > 8_000_000:
        continue
    try:
        text = p.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    if not word.search(text):
        continue
    lines = [l if keep.search(l) else word.sub("compat", l) for l in text.split("\n")]
    new = "\n".join(lines)
    if new != text:
        p.write_text(new, encoding="utf-8")
        n += 1
print(f"   comment wording neutral in {n} files")
EOF

echo "== libraries"
cp -pR "$S/freetype" "$STAGE/freetype"
cp -pR "$S/gnutls/gmp" "$STAGE/gmp"
cp -pR "$S/gnutls/gnutls" "$STAGE/gnutls"
cp "$DL/nettle-3.10.tar.gz" "$DL/ffmpeg-7.1.1.tar.xz" "$STAGE/"
# GStreamer as released (single-repository archive) and the subprojects its build fetched (glib, proxy-libintl,
# libffi, pcre2 with its meson build files, orc)
GST=$RT/gst-build/gstreamer-1.28.9
mkdir -p "$STAGE/gstreamer"
cp "$DL/gstreamer-mono-1.28.9.tar.gz" "$STAGE/gstreamer/gstreamer-1.28.9.tar.gz"
cp "$GST"/subprojects/packagecache/* "$STAGE/gstreamer/"
tar -C "$GST/subprojects" --exclude .git -czf "$STAGE/gstreamer/orc-0.4.42.tar.gz" orc
cp "$DL/MoltenVK-1.4.2.tar.gz" "$STAGE/"
# the DXVK backend: DXVK for macOS and its MoltenVK as in Wine's source archive (build-dxvk.sh patches them)
cp -pR "$S/dxvk" "$STAGE/dxvk-macos"
cp -pR "$S/moltenvk" "$STAGE/moltenvk-for-dxvk"
# OpenAL Soft as released, with the one-line build fix build-openal.sh applies
mkdir -p "$STAGE/openal-soft" "$STAGE/scripts/patches"
cp "$HOME/.tessera/build/downloads/redist/openal-soft-1.25.2.tar.gz" "$STAGE/openal-soft/"
cp "$HERE/patches/openal-soft-1.25.2-libcxx.patch" "$STAGE/openal-soft/"
cp "$HERE/patches/"*.patch "$STAGE/scripts/patches/"

echo "== Steam bridge"
cp -pR "$HOME/.tessera/build/bridge/src" "$STAGE/steam-bridge/lsteamclient"
cp -pR "$HERE/../bridge/steam-helper" "$STAGE/steam-bridge/steam-helper"

cp "$HERE/patch-wine.py" "$HERE/build-deps.sh" "$HERE/build-gstreamer.sh" "$HERE/build-moltenvk.sh" "$HERE/build-dxvk.sh" "$HERE/build-wine.sh" "$HERE/build-openal.sh" "$HERE/assemble.sh" \
   "$HERE/../bridge/build-bridge.sh" "$HERE/../bridge/mac-adapt.py" "$STAGE/scripts/"
cat > "$STAGE/README.txt" <<'EOF'
Sources of the Windows runtime inside Tessera

  wine/            Wine 11.0 (LGPL 2.1+) exactly as built for this release - Tessera's changes are already applied
                   (scripts/patch-wine.py lists them). Build with scripts/build-wine.sh --no-fresh.
  freetype/        FreeType (FreeType License / GPL 2)
  gmp/             GMP 6.3.0 (LGPL 3+ / GPL 2+)
  gnutls/          GnuTLS 3.8.3 (LGPL 2.1+)
  nettle-3.10.tar.gz   Nettle 3.10, official release (LGPL 3+ / GPL 2+)
  ffmpeg-7.1.1.tar.xz  FFmpeg 7.1.1, official release, built as LGPL (see scripts/build-deps.sh)
  gstreamer/       GStreamer 1.28.9 (LGPL 2.1+) as released, plus the sources its build fetched: glib 2.86.3
                   (LGPL 2.1+), proxy-libintl 0.5 (LGPL 2.1+), libffi (MIT), pcre2 10.47 (BSD), orc 0.4.42 (BSD).
                   Built by scripts/build-gstreamer.sh, which takes the pipe2() check out of glib's meson.build
                   (the function is new in macOS 27; the libraries also run on older macOS).
  MoltenVK-1.4.2.tar.gz  MoltenVK 1.4.2 as released (Apache 2.0); scripts/build-moltenvk.sh applies Tessera's change.
  dxvk-macos/            DXVK 1.10.3 for macOS (zlib), from the same source archive as Wine.
  moltenvk-for-dxvk/     the MoltenVK 1.2.10 fork DXVK for macOS is made for, with its SPIRV-Cross (Apache 2.0); used
                         only by games on DXVK. scripts/build-dxvk.sh builds both (with glslang 15.1.0 for DXVK's shaders).
  Wine Mono 10.4.1       shipped unchanged (share/wine/mono); its source is wine-mono-10.4.1-src.tar.xz, published next
                         to this archive (also at dl.winehq.org/wine/wine-mono/10.4.1/).
  Wine Gecko 2.47.4      shipped unchanged (share/wine/gecko, MPL 2.0); its source is wine-gecko-2.47.4-src.tar.xz,
                         published next to this archive (also at dl.winehq.org/wine/wine-gecko/2.47.4/).
  openal-soft/           OpenAL Soft 1.25.2 as released (LGPL 2.0+) and the one-line build fix Tessera applies
                         (openal-soft-1.25.2-libcxx.patch); scripts/build-openal.sh builds it for both Windows sides.
  steam-bridge/    lsteamclient from Valve's Proton, adapted for the macOS Steam client, and Tessera's steam.exe

Build order (macOS on Apple silicon, Xcode, llvm-mingw for the Windows side): scripts/build-deps.sh,
scripts/build-gstreamer.sh, scripts/build-wine.sh, scripts/build-bridge.sh, scripts/build-dxvk.sh, scripts/build-openal.sh,
scripts/assemble.sh. The scripts expect these folders under
~/.tessera/build (see the paths at the top of each script).
EOF
find "$STAGE" -name ".git" -prune -exec rm -rf {} +
echo "== archive"
tar -C "$TMP" -cJf "$OUT/$NAME.tar.xz" "$NAME"          # macOS tar writes xz itself
rm -rf "$TMP"
du -h "$OUT/$NAME.tar.xz" | cut -f1 | sed "s|^|   $OUT/$NAME.tar.xz: |"
