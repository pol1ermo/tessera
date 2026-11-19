#!/bin/bash
# build-moltenvk.sh - builds MoltenVK (Vulkan on Metal; Vulkan games and Wine's Vulkan paths use it) from the official
# 1.4.2 release with one Tessera change:
#
#   MVK_CONFIG_FRAGMENT_SUBGROUPS=0 - subgroup operations are reported for compute shaders only. In a Metal fragment
#   function the first thread of a SIMD group can be a helper thread, whose memory writes Metal drops; shaders that let
#   one elected thread write for its group then lose the write (Godot 4's clustered lights: black squares in Buckshot
#   Roulette, Godot issue 121201). Without subgroups in fragment shaders such games take their every-thread path.
#   Off unless the variable is set (Tessera's launcher sets it).
#
# Licence: Apache 2.0 (MoltenVK); the changed file carries a note. Output: $RT/deps/moltenvk/libMoltenVK.dylib
# (Intel + Apple silicon), which build-wine.sh takes.
set -euo pipefail
RT=${TESSERA_RT:-$HOME/.tessera/build/rt}
DL=$HOME/.tessera/build/downloads
B=$HOME/.tessera/build/moltenvk
VER=1.4.2
SHA16=6864db532f1dbbdb                  # first 16 hex digits of the release archive's SHA-256
step() { echo "== $1 ($(date +%H:%M:%S))"; }
mkdir -p "$DL" "$B" "$RT/deps/moltenvk"

step "source"
A=$DL/MoltenVK-$VER.tar.gz
[ -f "$A" ] || curl -fsSL -o "$A" "https://github.com/KhronosGroup/MoltenVK/archive/refs/tags/v$VER.tar.gz"
[ "$(shasum -a 256 "$A" | cut -c1-16)" = "$SHA16" ] || { echo "archive checksum differs"; exit 1; }
SRC=$B/MoltenVK-$VER
if [ ! -f "$SRC/.tessera-patched" ]; then
    rm -rf "$SRC" && tar -xzf "$A" -C "$B"
    python3 - "$SRC/MoltenVK/MoltenVK/GPUObjects/MVKDevice.mm" <<'PYEOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "\tpVk11Props->subgroupSupportedStages = VK_SHADER_STAGE_FRAGMENT_BIT | VK_SHADER_STAGE_COMPUTE_BIT;\n"
new = ("\tpVk11Props->subgroupSupportedStages = VK_SHADER_STAGE_COMPUTE_BIT;\n"
       "\t// Tessera: in a Metal fragment function the first thread of a SIMD group can be a helper thread, whose memory writes\n"
       "\t// Metal drops. Shaders that let one elected thread write for its group (Godot 4's clustered lights: black squares\n"
       "\t// on Apple GPUs, Godot issue 121201) then lose the write. MVK_CONFIG_FRAGMENT_SUBGROUPS=0 reports subgroups for\n"
       "\t// compute only, so such shaders take their every-thread path.\n"
       "\tconst char* fragmentSubgroups = getenv(\"MVK_CONFIG_FRAGMENT_SUBGROUPS\");\n"
       "\tif ( !(fragmentSubgroups && fragmentSubgroups[0] == '0') ) {\n"
       "\t\tpVk11Props->subgroupSupportedStages |= VK_SHADER_STAGE_FRAGMENT_BIT;\n"
       "\t}\n")
assert s.count(old) == 1, "subgroup stages line not found"
p.write_text(s.replace(old, new))
PYEOF
    touch "$SRC/.tessera-patched"
fi

step "dependencies (SPIRV-Cross, Vulkan headers, ... at the release's pinned versions)"
(cd "$SRC" && ./fetchDependencies --macos > "$B/fetch.log" 2>&1) || { tail -20 "$B/fetch.log"; exit 1; }

step "MoltenVK"
(cd "$SRC" && make macos > "$B/make.log" 2>&1) || { grep -E "error:|BUILD FAILED" "$B/make.log" | head -20; exit 1; }
LIB=$(find "$SRC/Package" -path "*dynamic*" -name libMoltenVK.dylib -path "*macOS*" | head -1)
[ -n "$LIB" ] || LIB=$(find "$SRC/Package" -name libMoltenVK.dylib | head -1)
cp "$LIB" "$RT/deps/moltenvk/libMoltenVK.dylib"
lipo -archs "$RT/deps/moltenvk/libMoltenVK.dylib"
strings -a "$RT/deps/moltenvk/libMoltenVK.dylib" | grep -c "MVK_CONFIG_FRAGMENT_SUBGROUPS" | sed 's/^/Tessera change present: /'
