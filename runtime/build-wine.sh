#!/bin/bash
# build-wine.sh - builds Tessera's Wine from the LGPL source with Tessera's changes (patch-wine.py).
#
#   1. fresh copy of the source + patch-wine.py
#   2. configure for macOS: Intel unix side (runs under Rosetta), 32- and 64-bit Windows side (llvm-mingw)
#   3. make + make install (DESTDIR) into $RT/wine-stage/opt/tessera
#
# Wine records its install folder inside ntdll.so, and source paths end up in assert messages, so the build uses
# a neutral prefix (/opt/tessera, staged under $RT/wine-stage) and maps source paths to /build: nothing in the
# shipped files names the build machine or its user.
#
# Needs build-deps.sh first (FreeType and GnuTLS are found there) and Tessera's own MoltenVK build.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RT=${TESSERA_RT:-$HOME/.tessera/build/rt}
SRC=$HOME/.tessera/build/sources/sources/wine
MOLTENVK=${TESSERA_MOLTENVK:-$HOME/.tessera/Runtimes/wine-11.0-tessera-20260907/lib64/libMoltenVK.dylib}
JOBS=$(sysctl -n hw.ncpu)
SDK=$(xcrun --show-sdk-path)
export PATH="$HOME/.tessera/build/llvm-mingw-20261117-ucrt-macos-universal/bin:$HOME/.tessera/build/tools/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=11.0
# llvm-mingw is first in PATH for the Windows side; the macOS side must use Apple's clang (its compiler-rt has
# __isPlatformVersionAtLeast, which @available checks in ntdll need)
APPLE_CLANG=$(xcrun -f clang)
APPLE_CLANGXX=$(xcrun -f clang++)
step() { echo "== $1 ($(date +%H:%M:%S))"; }

[ -f "$RT/deps/lib/libgnutls.30.dylib" ] || { echo "run build-deps.sh first"; exit 1; }
# configure finds MoltenVK by linking against it
mkdir -p "$RT/deps/lib"
cp "$MOLTENVK" "$RT/deps/lib/libMoltenVK.dylib"

MODE=${1:-}     # --no-fresh: keep the patched source; --resume: also keep the configured tree
if [ "$MODE" != "--no-fresh" ] && [ "$MODE" != "--resume" ]; then
    step "fresh source + Tessera changes"
    rm -rf "$RT/src/wine" "$RT/wine-build"
    mkdir -p "$RT/src"
    cp -cR "$SRC" "$RT/src/wine"
    python3 "$HERE/patch-wine.py" "$RT/src/wine" | head -3
fi

mkdir -p "$RT/wine-build"
cd "$RT/wine-build"
if [ "$MODE" != "--resume" ]; then
step "configure"
# game videos (Media Foundation -> winedmo) need FFmpeg; build-deps.sh makes it
if [ -f "$RT/deps/lib/libavcodec.61.dylib" ]; then
    FFMPEG_ARGS="--with-ffmpeg"
    export FFMPEG_CFLAGS="-I$RT/deps/include" FFMPEG_LIBS="-L$RT/deps/lib -lavformat -lavcodec -lavutil"
else
    FFMPEG_ARGS="--without-ffmpeg"
fi
# video and sound decoding for Windows Media, Media Foundation and DirectShow (winegstreamer) needs GStreamer;
# build-gstreamer.sh makes it
if [ -f "$RT/deps/lib/libgstreamer-1.0.0.dylib" ]; then
    GST_ARGS="--with-gstreamer"
    export GSTREAMER_CFLAGS="-I$RT/deps/include/gstreamer-1.0 -I$RT/deps/include/glib-2.0 -I$RT/deps/lib/glib-2.0/include"
    export GSTREAMER_LIBS="-L$RT/deps/lib -lgstvideo-1.0 -lgstaudio-1.0 -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0 -lgobject-2.0 -lglib-2.0"
else
    GST_ARGS="--without-gstreamer"
fi
"$RT/src/wine/configure" --prefix=/opt/tessera \
    --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-archs=i386,x86_64 \
    CC="$APPLE_CLANG -arch x86_64 -isysroot $SDK" CXX="$APPLE_CLANGXX -arch x86_64 -isysroot $SDK" \
    CFLAGS="-O2 -ffile-prefix-map=$RT=/build" CROSSCFLAGS="-O2 -ffile-prefix-map=$RT=/build" \
    CPPFLAGS="-I$RT/deps/include" LDFLAGS="-L$RT/deps/lib -Wl,-headerpad_max_install_names" \
    FREETYPE_CFLAGS="-I$RT/deps/include/freetype2" FREETYPE_LIBS="-L$RT/deps/lib -lfreetype" \
    GNUTLS_CFLAGS="-I$RT/deps/include" GNUTLS_LIBS="-L$RT/deps/lib -lgnutls" \
    --disable-tests --disable-win16 \
    --with-freetype --with-gnutls --with-cups --with-coreaudio --with-opencl --with-vulkan \
    $FFMPEG_ARGS $GST_ARGS --without-x --without-wayland --without-fontconfig \
    --without-sane --without-krb5 --without-gssapi --without-netapi --without-pcap --without-sdl --without-usb \
    --without-v4l2 --without-capi --without-gphoto --without-dbus --without-inotify --without-pulse \
    --without-alsa --without-oss --without-udev \
    > "$RT/wine-configure.log" 2>&1 || { tail -30 "$RT/wine-configure.log"; exit 1; }
grep -E "^configure: (WARNING|error)|libfreetype|libgnutls|MoltenVK" "$RT/wine-configure.log" | grep -v "^configure: WARNING: unrecognized" | head -20
grep -E "^#define SONAME_LIB(FREETYPE|GNUTLS|MOLTENVK|VULKAN|AVFORMAT|AVCODEC)|HAVE_FFMPEG" include/config.h || true
grep -q "^dlls/winegstreamer" Makefile 2>/dev/null && grep -c "winegstreamer" Makefile | sed "s/^/winegstreamer rules in Makefile: /" || true
fi

step "make"
make -j "$JOBS" > "$RT/wine-make.log" 2>&1 || { grep -E "error:|Error " "$RT/wine-make.log" | head -30; exit 1; }

step "install"
rm -rf "$RT/wine-stage"
make install DESTDIR="$RT/wine-stage" > "$RT/wine-install.log" 2>&1 || { tail -30 "$RT/wine-install.log"; exit 1; }
"$RT/wine-stage/opt/tessera/bin/wine" --version || true
du -sh "$RT/wine-stage/opt/tessera"
echo "home paths left in ntdll.so: $(strings -a "$RT/wine-stage/opt/tessera/lib/wine/x86_64-unix/ntdll.so" | grep -c "$HOME")"
step "done"
