#!/bin/bash
# build-dxvk.sh - builds the DXVK graphics backend: CodeWeavers' DXVK for macOS (Direct3D 9-11 -> Vulkan) and the
# MoltenVK it is made for, both from the CrossOver 26.3 source archive Tessera's Wine comes from.
#
#   DXVK      sources/dxvk (CodeWeavers' fork of DXVK 1.10.3), built with llvm-mingw for 64- and 32-bit Windows
#   MoltenVK  sources/moltenvk (CodeWeavers' fork of MoltenVK 1.2.10), with its SPIRV-Cross fork from the archive;
#             used only by games on DXVK (the runtime's own MoltenVK 1.4.2 stays for everything else)
#
# CodeWeavers' DXVK needs their MoltenVK: with the upstream MoltenVK 1.4.2 it crashes at once.
# Output: $RT/deps/dxvk/{x86_64-windows,i386-windows}/*.dll and $RT/deps/dxvk/libMoltenVK.dylib (Intel slice).
set -euo pipefail
RT=${TESSERA_RT:-$HOME/.tessera/build/rt}
DL=$HOME/.tessera/build/downloads
B=$HOME/.tessera/build/cx
ARCHIVE=$DL/crossover-sources-26.3.0.tar.gz
MINGW=$HOME/.tessera/build/llvm-mingw-20261117-ucrt-macos-universal/bin
MESON_TOOLS=$RT/gst-tools/bin                       # meson + ninja (build-gstreamer.sh's tools)
GLSLANG_TAG=15.1.0
GLSLANG_COMMIT=1062752a891c95b2bfeed9e356562d88f9df84ac
OUT=$RT/deps/dxvk
step() { echo "== $1 ($(date +%H:%M:%S))"; }
mkdir -p "$B" "$OUT"

step "sources"
if [ ! -f "$B/.tessera-patched" ]; then
    rm -rf "$B/sources"
    tar -xzf "$ARCHIVE" -C "$B" sources/dxvk sources/moltenvk
    # DXVK 1.10.3 predates today's MinGW headers and libc++:
    python3 - "$B/sources/dxvk" <<'PYEOF'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
def patch(rel, old, new):
    p = root / rel; s = p.read_text()
    assert s.count(old) == 1, rel
    p.write_text(s.replace(old, new))
# std::transform without <algorithm> (libstdc++ includes it indirectly, libc++ does not)
patch("src/util/config/config.cpp", "#include <array>\n", "#include <algorithm>\n#include <array>\n")
# MinGW 10 and later define these themselves
patch("src/d3d9/d3d9_include.h",
      "#ifndef _MSC_VER\ntypedef struct _D3DDEVINFO_RESOURCEMANAGER\n{\n  char dummy;\n} D3DDEVINFO_RESOURCEMANAGER, * LPD3DDEVINFO_RESOURCEMANAGER;\n",
      "#ifndef _MSC_VER\n#if !defined(__MINGW64_VERSION_MAJOR) || __MINGW64_VERSION_MAJOR < 10  /* Tessera: newer MinGW headers define it */\n"
      "typedef struct _D3DDEVINFO_RESOURCEMANAGER\n{\n  char dummy;\n} D3DDEVINFO_RESOURCEMANAGER, * LPD3DDEVINFO_RESOURCEMANAGER;\n#endif\n")
patch("src/d3d10/d3d10_interfaces.h",
      "#else\n__CRT_UUID_DECL(ID3D10StateBlock,",
      "#elif !defined(__MINGW64_VERSION_MAJOR) || __MINGW64_VERSION_MAJOR < 10  /* Tessera: newer MinGW headers declare it */\n__CRT_UUID_DECL(ID3D10StateBlock,")
PYEOF
    # today's Xcode builds for macOS 12 and later only
    find "$B/sources/moltenvk" -name project.pbxproj -exec sed -i '' -E 's/MACOSX_DEPLOYMENT_TARGET = 10\.[0-9]+;/MACOSX_DEPLOYMENT_TARGET = 12.0;/g' {} +
    # fetchDependencies would clone CodeWeavers' SPIRV-Cross fork next to their MoltenVK repository; the archive
    # carries it (External/SPIRV-Cross), so it is used from a copy (the script replaces External/SPIRV-Cross)
    rm -rf "$B/spirv-cross-cx" && cp -R "$B/sources/moltenvk/External/SPIRV-Cross" "$B/spirv-cross-cx"
    touch "$B/.tessera-patched"
fi

step "glslang $GLSLANG_TAG (DXVK compiles its shaders with glslangValidator)"
if [ ! -x "$B/glslang/build/StandAlone/glslang" ]; then
    rm -rf "$B/glslang"
    git clone -q --depth 1 --branch "$GLSLANG_TAG" https://github.com/KhronosGroup/glslang.git "$B/glslang"
    [ "$(git -C "$B/glslang" rev-parse HEAD)" = "$GLSLANG_COMMIT" ] || { echo "glslang $GLSLANG_TAG is not the expected commit"; exit 1; }
    (cd "$B/glslang" && python3 update_glslang_sources.py >/dev/null)
    cmake -S "$B/glslang" -B "$B/glslang/build" -DCMAKE_BUILD_TYPE=Release -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF >/dev/null
    cmake --build "$B/glslang/build" --target glslang-standalone -j"$(sysctl -n hw.ncpu)" >/dev/null
fi
mkdir -p "$B/tools" && ln -sf "$B/glslang/build/StandAlone/glslang" "$B/tools/glslangValidator"

step "MoltenVK (CodeWeavers)"
(cd "$B/sources/moltenvk" && ./fetchDependencies --macos --spirv-cross-root "$B/spirv-cross-cx" > "$B/fetch.log" 2>&1) \
    || { tail -20 "$B/fetch.log"; exit 1; }
# The defaults CodeWeavers builds it with (read from the libMoltenVK.dylib CrossOver 26.3 ships, through
# vkGetMoltenVKConfigurationMVK): with MoltenVK's own defaults - Metal argument buffers on, no full image-view
# swizzle - DXVK games draw garbage (Skyrim SE: green, dotted, black figures).
MVK_DEFAULTS=(MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0 MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1
              MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0 MVK_CONFIG_SHOULD_MAXIMIZE_CONCURRENT_COMPILATION=1
              MVK_CONFIG_SUPPORT_LARGE_QUERY_POOLS=0 MVK_CONFIG_RESUME_LOST_DEVICE=1 MVK_CONFIG_LOG_LEVEL=2)
(cd "$B/sources/moltenvk" && make macos "${MVK_DEFAULTS[@]}" > "$B/make.log" 2>&1) \
    || { grep -E "error:|BUILD FAILED" "$B/make.log" | head -20; exit 1; }
rm -f "$OUT/libMoltenVK.dylib"
lipo -thin x86_64 "$B/sources/moltenvk/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" -output "$OUT/libMoltenVK.dylib"

step "DXVK"
export PATH="$MINGW:$B/tools:$MESON_TOOLS:$PATH"
for bits in 64 32; do
    if [ $bits = 64 ]; then triple=x86_64; family=x86_64; dir=x86_64-windows; else triple=i686; family=x86; dir=i386-windows; fi
    cat > "$B/cross-win$bits.txt" <<EOF
[binaries]
c = '$triple-w64-mingw32-clang'
cpp = '$triple-w64-mingw32-clang++'
ar = '$triple-w64-mingw32-ar'
strip = '$triple-w64-mingw32-strip'
windres = '$triple-w64-mingw32-windres'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = '$family'
cpu = '$triple'
endian = 'little'
EOF
    rm -rf "$B/dxvk-build/build.w$bits" "$B/dxvk-build/out/x$bits"
    (cd "$B/sources/dxvk" && meson setup --cross-file "$B/cross-win$bits.txt" --buildtype release \
        --prefix "$B/dxvk-build/out" --bindir "x$bits" --libdir "x$bits" -Db_ndebug=if-release --strip \
        "$B/dxvk-build/build.w$bits" > "$B/dxvk-meson$bits.log" 2>&1) || { tail -20 "$B/dxvk-meson$bits.log"; exit 1; }
    ninja -C "$B/dxvk-build/build.w$bits" install > "$B/dxvk-ninja$bits.log" 2>&1 || { grep -E "error:|FAILED" "$B/dxvk-ninja$bits.log" | head -20; exit 1; }
    mkdir -p "$OUT/$dir"
    # Wine's own dxgi.dll goes with them (assemble.sh), as in CrossOver: CodeWeavers' DXVK presents through it
    for dll in d3d9 d3d10 d3d10_1 d3d10core d3d11; do cp "$B/dxvk-build/out/x$bits/$dll.dll" "$OUT/$dir/$dll.dll"; done
done
ls -la "$OUT" "$OUT/x86_64-windows" "$OUT/i386-windows" | grep -v "^total"
step "done"
