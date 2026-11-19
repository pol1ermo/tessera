#!/bin/bash
# build-gstreamer.sh - builds GStreamer for Wine's winegstreamer: the decoding behind game videos and sound that go
# through Windows Media (wmvcore), Media Foundation (mfplat/mfreadwrite) and DirectShow (quartz).
#
# Intel (x86_64) build like the other libraries (Wine's macOS half runs under Rosetta); meson runs under
# `arch -x86_64`. Built from GStreamer's single-repository release with only what Wine uses:
#   core           queue, multiqueue, typefind, capsfilter ...
#   base           playback (decodebin), typefind, audioconvert, audioresample, videoconvertscale
#   good           videofilter (videoflip), deinterlace, isomp4, matroska, avi, wavparse, audioparsers, id3demux
#   ugly           asfdemux (Windows Media .wmv/.wma files)
#   bad            videoparsers, mpegdemux, mpegtsdemux
#   libav          FFmpeg's decoders (Tessera's own LGPL FFmpeg from build-deps.sh)
# glib, libffi, pcre2, orc and proxy-libintl come from GStreamer's subprojects. Licences: GStreamer and glib LGPL,
# libffi MIT, pcre2 BSD, orc BSD. No GPL parts (gpl=disabled).
#
# Output: $RT/deps/lib (libraries), $RT/deps/lib/gstreamer-1.0 (plugins), $RT/deps/include (headers for Wine).
set -euo pipefail
RT=${TESSERA_RT:-$HOME/.tessera/build/rt}
DL=$HOME/.tessera/build/downloads
PREFIX=$RT/deps
BUILD=$RT/gst-build
TOOLS=$RT/gst-tools
GST_VERSION=1.28.9
GST_SHA256=0fdecabb02f170b7          # first 16 hex digits of the release archive's SHA-256
PY=/Library/Frameworks/Python.framework/Versions/3.12/bin/python3
JOBS=$(sysctl -n hw.ncpu)
X86="arch -x86_64"

export MACOSX_DEPLOYMENT_TARGET=11.0
export CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" OBJCXX="clang++ -arch x86_64"

step() { echo "== $1 ($(date +%H:%M:%S))"; }
mkdir -p "$BUILD" "$DL"

step "tools (meson, ninja, pkgconf in $TOOLS)"
if [ ! -x "$TOOLS/bin/meson" ]; then
    $X86 "$PY" -m venv "$TOOLS"
    $X86 "$TOOLS/bin/pip" install --quiet "meson>=1.4,<2" ninja pkgconf
fi
$X86 "$TOOLS/bin/meson" --version
export PATH="$TOOLS/bin:$PATH"

step "source"
ARCHIVE=$DL/gstreamer-mono-$GST_VERSION.tar.gz
[ -f "$ARCHIVE" ] || curl -fsSL -o "$ARCHIVE" \
    "https://gitlab.freedesktop.org/gstreamer/gstreamer/-/archive/$GST_VERSION/gstreamer-$GST_VERSION.tar.gz"
[ "$(shasum -a 256 "$ARCHIVE" | cut -c1-16)" = "$GST_SHA256" ] || { echo "archive checksum differs"; exit 1; }
SRC=$BUILD/gstreamer-$GST_VERSION
[ -d "$SRC" ] || tar -xzf "$ARCHIVE" -C "$BUILD"

# FFmpeg's pkg-config files name its neutral install prefix; point copies of them at the built libraries
step "FFmpeg for gst-libav"
mkdir -p "$BUILD/pc"
for pc in "$PREFIX"/lib/pkgconfig/libav*.pc "$PREFIX"/lib/pkgconfig/libsw*.pc; do
    sed "s|/opt/tessera-deps|$PREFIX|g" "$pc" > "$BUILD/pc/$(basename "$pc")"
done
export PKG_CONFIG_PATH=$BUILD/pc PKG_CONFIG=$TOOLS/bin/pkgconf

step "configure"
OUT=$BUILD/out
if [ ! -f "$OUT/build.ninja" ]; then
$X86 "$TOOLS/bin/meson" setup "$OUT" "$SRC" \
    --prefix=/opt/tessera-deps --libdir=lib --buildtype=release --default-library=shared --wrap-mode=default \
    -Dauto_features=disabled -Dbase=enabled -Dgood=enabled -Dugly=enabled -Dbad=enabled -Dlibav=enabled \
    -Dorc=enabled -Dgpl=disabled -Dtools=disabled -Dtests=disabled -Dexamples=disabled -Ddoc=disabled \
    -Dintrospection=disabled -Dnls=disabled -Dpython=disabled -Dges=disabled -Drtsp_server=disabled \
    -Ddevtools=disabled -Dlibnice=disabled -Dgst-examples=disabled -Drs=disabled -Dsharp=disabled -Dtls=disabled \
    -Dgstreamer:ptp-helper=disabled -Dgstreamer:check=enabled -Dgstreamer:libunwind=disabled \
    -Dgstreamer:libdw=disabled -Dgstreamer:coretracers=disabled -Dgstreamer:bash-completion=disabled \
    -Dgst-plugins-base:playback=enabled -Dgst-plugins-base:typefind=enabled \
    -Dgst-plugins-base:audioconvert=enabled -Dgst-plugins-base:audioresample=enabled \
    -Dgst-plugins-base:videoconvertscale=enabled \
    -Dgst-plugins-good:videofilter=enabled -Dgst-plugins-good:deinterlace=enabled \
    -Dgst-plugins-good:isomp4=enabled -Dgst-plugins-good:matroska=enabled -Dgst-plugins-good:avi=enabled \
    -Dgst-plugins-good:wavparse=enabled -Dgst-plugins-good:audioparsers=enabled -Dgst-plugins-good:id3demux=enabled \
    -Dgst-plugins-ugly:asfdemux=enabled \
    -Dgst-plugins-bad:videoparsers=enabled -Dgst-plugins-bad:mpegdemux=enabled -Dgst-plugins-bad:mpegtsdemux=enabled \
    -Dglib:tests=false \
    > "$BUILD/configure.log" 2>&1 || { tail -40 "$BUILD/configure.log"; exit 1; }
fi
grep -E "^  (Subprojects|    [a-z-]+ *: *(YES|NO))|Run-time dependency (libav|glib|orc)" "$BUILD/configure.log" | head -30 || true

step "build"
$X86 "$TOOLS/bin/meson" compile -C "$OUT" -j "$JOBS" > "$BUILD/build.log" 2>&1 \
    || { grep -E "error|Error" "$BUILD/build.log" | head -30; exit 1; }

step "install (staged)"
rm -rf "$BUILD/stage"
DESTDIR="$BUILD/stage" $X86 "$TOOLS/bin/meson" install -C "$OUT" --no-rebuild > "$BUILD/install.log" 2>&1 \
    || { tail -20 "$BUILD/install.log"; exit 1; }
S=$BUILD/stage/opt/tessera-deps
mkdir -p "$PREFIX/lib/gstreamer-1.0" "$PREFIX/include"
cp -R "$S/lib/." "$PREFIX/lib/"
cp -R "$S/include/." "$PREFIX/include/"
echo "libraries: $(cd "$S/lib" && ls *.dylib | grep -v -E '\.[0-9]+\.dylib$' | wc -l | tr -d ' ')," \
     "plugins: $(ls "$S/lib/gstreamer-1.0" | wc -l | tr -d ' ')," \
     "size $(du -sh "$S/lib" | cut -f1)"
ls "$S/lib/gstreamer-1.0"
