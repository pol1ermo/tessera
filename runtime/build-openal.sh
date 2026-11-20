#!/bin/bash
# build-openal.sh - builds OpenAL Soft (LGPL 2.0 or later) for 64- and 32-bit Windows with llvm-mingw.
#
# Windows has no OpenAL of its own and Wine has no openal32.dll: games that link OpenAL32.dll without shipping it
# (they rely on Creative's old installer having run) stopped at start. Tessera puts this build into every Windows
# folder's system32/syswow64 (the launcher's Windows extras), where Creative's installer would have put its own;
# a game that brings its own OpenAL32.dll keeps using that one (Windows looks in the game's folder first).
#
# Output: $RT/openal/{x86_64,i386}/OpenAL32.dll and $RT/openal/licenses/
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
B=$HOME/.tessera/build
RT=${TESSERA_RT:-$B/rt}
VERSION=1.25.2
SHA256=fb27e5839aa11f0e5b9d33756965291fad5d6909ab928ea1f796f4a1a6877894    # openal-soft-1.25.2.tar.gz (GitHub tag)
TAR=$B/downloads/redist/openal-soft-$VERSION.tar.gz
MINGW=$(ls -d "$B"/llvm-mingw-*/bin | head -1)
OUT=$RT/openal
step() { echo "== $1 ($(date +%H:%M:%S))"; }

step "source"
mkdir -p "$(dirname "$TAR")"
[ -f "$TAR" ] || curl -fsSL --retry 3 -o "$TAR" "https://github.com/kcat/openal-soft/archive/refs/tags/$VERSION.tar.gz"
[ "$(shasum -a 256 "$TAR" | cut -d' ' -f1)" = "$SHA256" ] || { echo "openal-soft-$VERSION.tar.gz: checksum mismatch"; exit 1; }
SRC=$B/openal-soft-$VERSION
rm -rf "$SRC"
tar -C "$B" -xzf "$TAR"
# one line newer libc++ does not accept (patches/openal-soft-1.25.2-libcxx.patch says why)
(cd "$SRC" && patch -p1 -s < "$HERE/patches/openal-soft-$VERSION-libcxx.patch")

rm -rf "$OUT"
for arch in x86_64 i686; do
    step "build $arch"
    dir=$B/openal-build-$arch
    rm -rf "$dir"
    # HAVE_WFUNCTION_EFFECTS=OFF: OpenAL Soft makes clang's real-time-safety analysis (-Wfunction-effects) an error on
    # Windows, and clang 23 reports its own narrowing check inside the mixers on 32-bit; the analysis is only a check
    cmake -S "$SRC" -B "$dir" -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=$arch \
        -DCMAKE_C_COMPILER="$MINGW/$arch-w64-mingw32-clang" -DCMAKE_CXX_COMPILER="$MINGW/$arch-w64-mingw32-clang++" \
        -DCMAKE_RC_COMPILER="$MINGW/$arch-w64-mingw32-windres" -DCMAKE_BUILD_TYPE=Release \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF -DALSOFT_INSTALL=OFF \
        -DALSOFT_STATIC_LIBGCC=ON -DALSOFT_STATIC_STDCXX=ON -DHAVE_WFUNCTION_EFFECTS=OFF \
        > "$B/openal-cmake-$arch.log" 2>&1 || { tail -20 "$B/openal-cmake-$arch.log"; exit 1; }
    make -C "$dir" -j "$(sysctl -n hw.ncpu)" > "$B/openal-make-$arch.log" 2>&1 \
        || { grep -E "error" "$B/openal-make-$arch.log" | head -20; exit 1; }
    win=$([ $arch = x86_64 ] && echo x86_64 || echo i386)
    mkdir -p "$OUT/$win"
    cp "$dir/OpenAL32.dll" "$OUT/$win/OpenAL32.dll"
    # only Windows' own DLLs and the Universal CRT may be imported (libc++ and the unwinder are linked in)
    if "$MINGW/llvm-objdump" -p "$OUT/$win/OpenAL32.dll" | awk '/DLL Name/ {print tolower($3)}' \
        | grep -v -E '^(api-ms-win-crt-.*|kernel32|user32|ole32|shell32|winmm|avrt)\.dll$'; then
        echo "OpenAL32.dll ($arch) imports a DLL Windows does not have"; exit 1
    fi
done

step "licences"
mkdir -p "$OUT/licenses"
{
    echo "OpenAL Soft $VERSION - https://github.com/kcat/openal-soft"
    echo "Built by Tessera for Windows from the unmodified release, plus the one-line build fix in"
    echo "patches/openal-soft-$VERSION-libcxx.patch (in tessera-runtime-src next to each release)."
    echo
    echo "=== OpenAL Soft: GNU Library General Public License 2 or later (COPYING) ==="
    cat "$SRC/COPYING"
    echo
    echo "=== PFFFT, modified, included in OpenAL Soft (LICENSE-pffft) ==="
    cat "$SRC/LICENSE-pffft"
    echo
    echo "=== Built-in HRTF data (headphone 3D audio) ==="
    echo "OpenAL Soft's default HRTF data set is made from the KEMAR HRTF measurements by Bill Gardner and"
    echo "Keith Martin, MIT Media Laboratory (http://sound.media.mit.edu/resources/KEMAR.html), which MIT"
    echo "provides free with no restrictions on use, provided the authors are cited."
} > "$OUT/licenses/OpenAL Soft - LGPL 2.0 and notices.txt"
ls -la "$OUT"/*/OpenAL32.dll
step "done"
