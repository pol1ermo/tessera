#!/bin/bash
# build-bridge.sh - builds Tessera's Steam bridge: Valve's Proton "lsteamclient" (the Windows Steam API that games
# load, forwarded to the native Mac Steam client), compiled the way Wine compiles its own modules.
#
# Inputs (outside iCloud, ~/.tessera/build):
#   sources/proton/lsteamclient   Valve's source (Proton, proton_11.0 branch)
#   sources/sources/wine          the Wine source the runtime is built from
#   wine-bridge                   a configured Wine build tree with tools and import libraries
#   llvm-mingw-*                  the Windows cross compiler
# Output: $OUT/{x86_64-windows/lsteamclient.dll, i386-windows/lsteamclient.dll, x86_64-unix/lsteamclient.so}
# Wine finds a builtin by the name inside the DLL (lsteamclient.dll), so the runtime keeps that name; only the
# placeholder copies in a prefix are called steamclient64.dll / steamclient.dll.
set -euo pipefail
B=${TESSERA_BUILD:-$HOME/.tessera/build}
W=$B/sources/sources/wine
WB=$B/wine-bridge
SRC=$B/bridge/src
OBJ=$B/bridge/obj
OUT=${OUT:-$B/bridge/out}
RUNTIME=${TESSERA_RUNTIME:-$HOME/.tessera/Runtimes/wine-11.0-tessera-20260907}
HERE=$(cd "$(dirname "$0")" && pwd)
export PATH="$B/tools/bin:$(ls -d "$B"/llvm-mingw-*/bin | head -1):$PATH"
SDK=$(xcrun --show-sdk-path)
JOBS=$(sysctl -n hw.ncpu)

echo "== preparing source"
rm -rf "$SRC" "$OBJ"
mkdir -p "$SRC" "$OBJ" "$OUT"
cp -R "$B/sources/proton/lsteamclient/." "$SRC/"
python3 "$HERE/mac-adapt.py" "$SRC"

SOURCES=$(awk '/^SOURCES/{f=1} f{print} /^$/{if(f)exit}' "$SRC/Makefile.in" | tr -d '\\' | tr -s ' \t' '\n' | grep -E '\.(c|cpp)$')
PE_SOURCES=$(echo "$SOURCES" | grep '\.c$')
UNIX_SOURCES=$(echo "$SOURCES" | grep '\.cpp$')
DEFS="-DSTEAM_API_EXPORTS -Dprivate=public -Dprotected=public"

# Windows half, as Wine builds a builtin DLL: MinGW clang, Wine headers, msvcrt headers, ucrt.
build_pe() {
    local arch=$1 target=$2 out=$3
    local cc="$arch-w64-mingw32-gcc -D__STDC__"
    [ "$arch" = i386 ] && cc="i686-w64-mingw32-gcc -D__STDC__"
    local flags="-D__WINE_PE_BUILD -Wall -target $target -fuse-ld=lld --no-default-config -fno-strict-aliasing
        -ffunction-sections -fasync-exceptions -ffp-exception-behavior=maytrap -fms-hotpatch -gdwarf-4 -g -O2
        -ffile-prefix-map=$HOME/.tessera/build=/build
        -D_WIN32 -fno-builtin -fshort-wchar -Wno-format"
    [ "$arch" = x86_64 ] && flags="$flags -mcx16 -mcmodel=small"
    local inc="-I$SRC -I$WB/include -I$W/include -I$W/include/msvcrt -D_UCRT -D__WINESRC__"
    mkdir -p "$OBJ/$arch"
    echo "== Windows half ($arch): $(echo "$PE_SOURCES" | wc -l | tr -d ' ') files"
    printf '#!/bin/sh\n%s -c -o "%s/$1.o" "%s/$1" %s %s %s 2>>"%s.log" || { echo "FAILED: $1"; exit 255; }\n' \
        "$cc" "$OBJ/$arch" "$SRC" "$inc" "$DEFS" "$(echo $flags)" "$OBJ/$arch" > "$OBJ/cc-$arch.sh"
    chmod +x "$OBJ/cc-$arch.sh"
    echo "$PE_SOURCES" | xargs -P "$JOBS" -n 1 "$OBJ/cc-$arch.sh"
    local libs=""
    for d in user32 ws2_32 winecrt0; do libs="$libs $WB/dlls/$d/$arch-windows/lib$d.a"; done
    libs="$libs $WB/libs/compiler-rt/$arch-windows/libcompiler-rt.a"
    for d in ucrtbase kernel32 ntdll; do libs="$libs $WB/dlls/$d/$arch-windows/lib$d.a"; done
    "$WB/tools/winegcc/winegcc" -o "$OUT/$arch-windows/$out" --wine-objdir "$WB" -b "$target" -Wl,--wine-builtin \
        -shared "$SRC/lsteamclient.spec" "$OBJ/$arch"/*.o $libs --no-default-config -fms-hotpatch -Wl,-debug:dwarf
    echo "   -> $OUT/$arch-windows/$out"
}

mkdir -p "$OUT/x86_64-windows" "$OUT/i386-windows" "$OUT/x86_64-unix"
build_pe x86_64 x86_64-windows lsteamclient.dll
build_pe i386 i686-windows lsteamclient.dll

# Mac half: the generated C++ wrappers plus unixlib.cpp, linked against Wine's ntdll.so.
echo "== Mac half: $(echo "$UNIX_SOURCES" | wc -l | tr -d ' ') files"
mkdir -p "$OBJ/unix"
# Apple's clang++ explicitly: llvm-mingw may come first in PATH
CXX="$(xcrun -f clang++) -arch x86_64 -isysroot $SDK -m64"
UFLAGS="-std=c++17 -DNOMINMAX -include cwchar -include cstring -include array -Wall -pipe -fcf-protection=none -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing
        -g -O2 -fPIC -ffile-prefix-map=$HOME/.tessera/build=/build -I$SRC -I$WB/include -I$W/include -D__WINESRC__ -DWINE_UNIX_LIB -U_FORTIFY_SOURCE
        -D_FORTIFY_SOURCE=0 -Wno-unused-variable -Wno-unused-function"
printf '#!/bin/sh\n%s -c -o "%s/$1.o" "%s/$1" %s %s 2>>"%s/unix.log" || { echo "FAILED: $1"; exit 255; }\n' \
    "$CXX" "$OBJ/unix" "$SRC" "$DEFS" "$(echo $UFLAGS)" "$OBJ" > "$OBJ/cc-unix.sh"
chmod +x "$OBJ/cc-unix.sh"
echo "$UNIX_SOURCES" | xargs -P "$JOBS" -n 1 "$OBJ/cc-unix.sh"
$CXX -o "$OUT/x86_64-unix/lsteamclient.so" -dynamiclib -install_name @rpath/lsteamclient.so \
    -Wl,-rpath,@loader_path/ -Wl,-rpath,@loader_path/../../wine/x86_64-unix "$OBJ/unix"/*.o \
    "$RUNTIME/lib/wine/x86_64-unix/ntdll.so"
# 32-bit games run their Windows half through WoW64 and use the same 64-bit Mac half.
codesign -f -s - "$OUT/x86_64-unix/lsteamclient.so" 2>/dev/null
echo "   -> $OUT/x86_64-unix/lsteamclient.so"

# steam.exe: Tessera's stand-in for the Windows Steam client (steam-helper/), as Wine built-ins for both architectures.
# Wine runs them in place of the signed Valve file the prefix's Steam folder holds (steam.exe=b).
echo "== steam.exe"
for arch in x86_64 i386; do
    cc=x86_64-w64-mingw32-clang; [ $arch = i386 ] && cc=i686-w64-mingw32-clang
    mkdir -p "$OUT/$arch-windows"
    $cc -O2 -municode -mwindows -Wall -ffile-prefix-map=$HOME=/build -o "$OUT/$arch-windows/steam.exe" \
        "$HERE/steam-helper/steam_helper.c" -ladvapi32 -luser32
    "$WB/tools/winebuild/winebuild" --builtin "$OUT/$arch-windows/steam.exe"
    echo "   -> $OUT/$arch-windows/steam.exe"
done
echo "== done"
