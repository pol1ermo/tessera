#!/bin/bash
# build-deps.sh - builds the libraries Tessera's Wine loads at run time, from source:
#   FreeType (fonts), GMP + Nettle + GnuTLS (secure connections: bcrypt, crypt32, secur32), FFmpeg (game videos).
#
# Wine's macOS half runs as Intel code under Rosetta, so these are Intel (x86_64) builds too. The configure
# scripts run under Rosetta (`arch -x86_64`) so they see a native x86_64 machine and can run their test programs.
#
# Sources: the LGPL source bundle in ~/.tessera/build/sources (FreeType, GMP, GnuTLS) and the official Nettle
# release tarball (the bundle's Nettle is a git checkout without a configure script).
# Output: $RT/deps/{include,lib}; install names are fixed to @rpath later by assemble.sh.
set -euo pipefail
RT=${TESSERA_RT:-$HOME/.tessera/build/rt}
SRC=$HOME/.tessera/build/sources/sources
DL=$HOME/.tessera/build/downloads
PREFIX=$RT/deps
BUILD=$RT/deps-build
JOBS=$(sysctl -n hw.ncpu)
SDK=$(xcrun --show-sdk-path)
NETTLE_URL=https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz
FFMPEG_VERSION=7.1.1

export MACOSX_DEPLOYMENT_TARGET=11.0
export CC="clang -arch x86_64"
export CFLAGS="-O2 -isysroot $SDK -ffile-prefix-map=$RT=/build"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-isysroot $SDK -L$PREFIX/lib -Wl,-headerpad_max_install_names"
X86="arch -x86_64"

step() { echo "== $1 ($(date +%H:%M:%S))"; }
mkdir -p "$BUILD" "$PREFIX" "$DL"

built() { [ -f "$PREFIX/lib/$1" ] && echo "   already built"; }

step "FreeType"
built libfreetype.6.dylib || {
rm -rf "$BUILD/freetype"
cmake -S "$SRC/freetype" -B "$BUILD/freetype" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DBUILD_SHARED_LIBS=ON \
    -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DFT_REQUIRE_ZLIB=ON \
    > "$BUILD/freetype.log" 2>&1
cmake --build "$BUILD/freetype" -j "$JOBS" >> "$BUILD/freetype.log" 2>&1
cmake --install "$BUILD/freetype" >> "$BUILD/freetype.log" 2>&1
# CMake names it @rpath/...; Wine's build tools (sfnt2fon) need the real location. assemble.sh sets @rpath for shipping.
install_name_tool -id "$PREFIX/lib/libfreetype.6.dylib" "$PREFIX/lib/libfreetype.6.dylib" 2>/dev/null
codesign -f -s - "$PREFIX/lib/libfreetype.6.dylib" 2>/dev/null
}

# cp -p keeps file dates: otherwise make thinks configure is stale and tries to run autoconf
step "GMP"
built libgmp.10.dylib || {
rm -rf "$BUILD/gmp" && cp -pR "$SRC/gnutls/gmp" "$BUILD/gmp"
(cd "$BUILD/gmp" && $X86 ./configure --prefix="$PREFIX" --enable-shared --disable-static > ../gmp.log 2>&1 \
    && $X86 make -j "$JOBS" >> ../gmp.log 2>&1 && $X86 make install >> ../gmp.log 2>&1)
}

step "Nettle"
built libnettle.8.dylib || {
[ -f "$DL/nettle-3.10.tar.gz" ] || curl -fsSL -o "$DL/nettle-3.10.tar.gz" "$NETTLE_URL"
rm -rf "$BUILD/nettle-3.10" && tar -xzf "$DL/nettle-3.10.tar.gz" -C "$BUILD"
(cd "$BUILD/nettle-3.10" && $X86 ./configure --prefix="$PREFIX" --enable-shared --disable-static \
    --disable-documentation --disable-openssl > ../nettle.log 2>&1 \
    && $X86 make -j "$JOBS" >> ../nettle.log 2>&1 && $X86 make install >> ../nettle.log 2>&1)
}

# GnuTLS tests these variables unquoted (`test x$NETTLE_LIBS = x`): a value with a space silently turns off its
# crypto backend, so they are single words and the library folder comes from LDFLAGS.
step "GnuTLS"
built libgnutls.30.dylib || {
rm -rf "$BUILD/gnutls" && cp -pR "$SRC/gnutls/gnutls" "$BUILD/gnutls"
(cd "$BUILD/gnutls" && \
    NETTLE_CFLAGS="-I$PREFIX/include" NETTLE_LIBS="-lnettle" \
    HOGWEED_CFLAGS="-I$PREFIX/include" HOGWEED_LIBS="-lhogweed" \
    GMP_CFLAGS="-I$PREFIX/include" GMP_LIBS="-lgmp" \
    $X86 ./configure --prefix="$PREFIX" --enable-shared --disable-static \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit --without-idn \
        --without-brotli --without-zstd --without-tpm --without-tpm2 --without-leancrypto \
        --disable-doc --disable-manpages --disable-tests --disable-tools --disable-cxx --disable-guile \
        --disable-nls --disable-openssl-compatibility --disable-full-test-suite --disable-ktls \
        --disable-maintainer-mode \
        > ../gnutls.log 2>&1 \
    && $X86 make -j "$JOBS" >> ../gnutls.log 2>&1 && $X86 make install >> ../gnutls.log 2>&1) \
    || { grep -E "error:|Error [0-9]" "$BUILD/gnutls.log" | head -20; exit 1; }
}

# FFmpeg (LGPL build: no --enable-gpl / --enable-nonfree): Wine's media foundation (winedmo) decodes game videos
# with it. No nasm here, so without x86 assembly (Rosetta translates the C code either way).
step "FFmpeg"
built libavcodec.61.dylib || {
[ -f "$DL/ffmpeg-$FFMPEG_VERSION.tar.xz" ] || curl -fsSL -o "$DL/ffmpeg-$FFMPEG_VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
rm -rf "$BUILD/ffmpeg-$FFMPEG_VERSION" && tar -xJf "$DL/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$BUILD"
# FFmpeg keeps its whole configure line inside libavutil, so it is configured for a neutral prefix and staged
(cd "$BUILD/ffmpeg-$FFMPEG_VERSION" && $X86 ./configure --prefix=/opt/tessera-deps --cc="clang -arch x86_64" \
    --enable-shared --disable-static --disable-programs --disable-doc --disable-network --disable-x86asm \
    --disable-avdevice --disable-postproc --disable-autodetect --enable-zlib --enable-pic \
    --install-name-dir=/opt/tessera-deps/lib > ../ffmpeg.log 2>&1 \
    && $X86 make -j "$JOBS" >> ../ffmpeg.log 2>&1 && rm -rf ../ffmpeg-stage \
    && $X86 make install DESTDIR="$BUILD/ffmpeg-stage" >> ../ffmpeg.log 2>&1 \
    && cp -R "$BUILD/ffmpeg-stage/opt/tessera-deps/lib/." "$PREFIX/lib/" \
    && cp -R "$BUILD/ffmpeg-stage/opt/tessera-deps/include/." "$PREFIX/include/") \
    || { grep -E "error|ERROR" "$BUILD/ffmpeg.log" | head -20; exit 1; }
}

step "done"
ls -la "$PREFIX/lib"/*.dylib | awk '{print $NF}'
for l in "$PREFIX"/lib/libfreetype.6.dylib "$PREFIX"/lib/libgnutls.30.dylib; do lipo -info "$l"; done
