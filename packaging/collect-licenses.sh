#!/bin/bash
# collect-licenses.sh DEST - writes the licence texts of everything Tessera ships into DEST (Tessera.app's
# Contents/Resources/Licenses). Wine and the libraries are LGPL: their complete source, with Tessera's changes,
# has to be published next to every release that ships them (runtime/package-sources.sh makes that archive).
set -euo pipefail
DEST=${1:?usage: collect-licenses.sh DEST}
S=$HOME/.tessera/build/sources/sources
P=$HOME/.tessera/build/sources/proton
L=$HOME/.tessera/build/licenses-src
RT=$HOME/.tessera/build/rt
GPTK_DMG=${TESSERA_GPTK_DMG:-$HOME/Downloads/Game_Porting_Toolkit_4.0_beta_3.dmg}
mkdir -p "$DEST" "$L"

cp "$S/wine/COPYING.LIB"              "$DEST/Wine - LGPL 2.1.txt"
cp "$S/wine/AUTHORS"                  "$DEST/Wine - authors.txt"
cp "$S/freetype/docs/FTL.TXT"         "$DEST/FreeType - FreeType License.txt"
cp "$S/gnutls/gnutls/LICENSE"         "$DEST/GnuTLS - licensing.txt"
cp "$S/gnutls/gnutls/doc/COPYING.LESSER" "$DEST/GnuTLS - LGPL 2.1.txt"
cp "$RT/deps-build/nettle-3.10/COPYING.LESSERv3" "$DEST/Nettle - LGPL 3.txt"
cp "$S/gnutls/gmp/COPYING.LESSERv3"   "$DEST/GMP - LGPL 3.txt"
cp "$S/moltenvk/LICENSE"              "$DEST/MoltenVK - Apache 2.0.txt"
cp "$S/dxvk/LICENSE"                  "$DEST/DXVK - zlib.txt"
cp "$S/moltenvk/LICENSE"              "$DEST/MoltenVK for DXVK - Apache 2.0.txt"
FF=$RT/deps-build/ffmpeg-7.1.1
cp "$FF/COPYING.LGPLv2.1"             "$DEST/FFmpeg - LGPL 2.1.txt"
cp "$FF/LICENSE.md"                   "$DEST/FFmpeg - licensing.txt"
GST=$RT/gst-build/gstreamer-1.28.9
cp "$GST/LICENSE"                     "$DEST/GStreamer - LGPL 2.1.txt"
cp "$GST/subprojects/glib-2.86.3/COPYING" "$DEST/GLib - LGPL 2.1.txt"
cp "$GST/subprojects/proxy-libintl-0.5/COPYING" "$DEST/proxy-libintl - LGPL 2.1.txt"
cp "$GST/subprojects/libffi-meson-3.2.9999.5/LICENSE" "$DEST/libffi - MIT.txt"
cp "$GST/subprojects/pcre2-10.47/LICENCE.md" "$DEST/PCRE2 - BSD.txt"
cp "$GST/subprojects/orc/COPYING"     "$DEST/orc - BSD.txt"
cp "$L/DXMT-LICENSE.txt"              "$DEST/DXMT - MIT.txt"
cp "$L/WineMono-COPYING.txt"           "$DEST/Wine Mono - licences (LGPL, MIT and others).txt"
cp "$P/LICENSE"                       "$DEST/Steam bridge - Proton.txt"
cp "$P/LICENSE.proton"                "$DEST/Steam bridge - Proton license.txt"
cp "$P/lsteamclient/LICENSE"          "$DEST/Steam bridge - Steamworks SDK.txt"

# Apple's D3DMetal: the Game Porting Toolkit licence and acknowledgements, plus the notice inside the framework
# The LGPL 3 (Nettle, GMP) is a set of extra permissions on top of the GPL 3, whose text has to come with it;
# Wine Mono's SharpZipLib is GPL 2 with a linking exception.
cp "$RT/deps-build/nettle-3.10/COPYINGv3" "$DEST/GNU GPL 3 (with the LGPL 3 of Nettle and GMP).txt"
cp "$RT/deps-build/nettle-3.10/COPYINGv2" "$DEST/GNU GPL 2.txt"
# Libraries in Wine's source tree (libs/) that Wine builds into its Windows DLLs, each with its own licence
{
    echo "Libraries that Wine carries in its source tree (libs/) and builds into its Windows DLLs, with their licences."
    echo "This software is based in part on the work of the Independent JPEG Group (libjpeg)."
    for entry in "capstone:LICENSE.TXT LICENSE_LLVM.TXT" "compiler-rt:LICENSE.TXT" "faudio:LICENSE" \
                 "fluidsynth:COPYING.md" "gsm:COPYRIGHT" "jpeg:LICENSE" "jxr:LICENSE" "lcms2:COPYING" \
                 "ldap:COPYRIGHT LICENSE" "mpg123:LICENSE" "musl:COPYRIGHT" "png:LICENSE" "tiff:COPYRIGHT" \
                 "tomcrypt:LICENSE" "vkd3d:COPYING" "xml2:COPYING" "xslt:COPYING" "zlib:LICENSE"; do
        lib=${entry%%:*}
        for f in ${entry#*:}; do
            printf '\n\n==================== %s (Wine libs/%s/%s) ====================\n\n' "$lib" "$lib" "$f"
            cat "$S/wine/libs/$lib/$f"
        done
    done
} > "$DEST/Wine - bundled libraries (libjpeg, libpng, libtiff, zlib and others).txt"
# LLVM: DXMT links it into its shader converter (winemetal.so); DXVK's DLLs carry LLVM's C++ runtime
cp "$HOME/.tessera/build/llvm-mingw-20261117-ucrt-macos-universal/LICENSE.TXT" "$DEST/LLVM - Apache 2.0 with LLVM exceptions.txt"
# DXVK's DLLs are statically linked with the MinGW-w64 runtime, whose notices must come with the binaries
[ -f "$L/MinGW-w64-runtime-COPYING.txt" ] || curl -fsSL -o "$L/MinGW-w64-runtime-COPYING.txt" \
    https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt
cp "$L/MinGW-w64-runtime-COPYING.txt" "$DEST/MinGW-w64 runtime - licences.txt"
# Built into MoltenVK (both builds)
cp "$HOME/.tessera/build/moltenvk/MoltenVK-1.4.2/External/cereal/LICENSE" "$DEST/MoltenVK - cereal - BSD.txt"
cp "$HOME/.tessera/build/moltenvk/MoltenVK-1.4.2/External/SPIRV-Cross/LICENSE" "$DEST/MoltenVK - SPIRV-Cross - Apache 2.0.txt"
cp "$S/dxvk/include/openvr/LICENSE"   "$DEST/DXVK - OpenVR headers - BSD.txt"
# Wine Mono's components: their licence files from the Wine Mono source archive (published next to each release)
WM=$L/winemono/wine-mono-10.4.1
WMFILES="COPYING mono/LICENSE mono/mcs/class/ICSharpCode.SharpZipLib/README mono/external/corefx/LICENSE.TXT
         mono/external/corert/LICENSE.TXT mono/external/cecil/LICENSE.txt mono/external/aspnetwebstack/License.txt
         mono/external/boringssl/LICENSE FNA/licenses/LICENSE FNA.NetStub/LICENSE FNA/lib/FAudio/LICENSE
         FNA/lib/FNA3D/LICENSE FNA/lib/FNA3D/MojoShader/LICENSE.txt FNA/lib/SDL2-CS/LICENSE FNA/lib/SDL3-CS/LICENSE
         FNA/lib/Theorafile/licenses/LICENSE SDL3/LICENSE.txt winforms/LICENSE.TXT
         winforms-datavisualization/LICENSE.TXT wpf/LICENSE.TXT monoDX/LICENSE"
if [ ! -f "$WM/mono/LICENSE" ]; then
    mkdir -p "$L/winemono"
    for f in $WMFILES; do echo "wine-mono-10.4.1/$f"; done > "$L/winemono/members.txt"
    tar -xJf "$HOME/.tessera/build/downloads/winemono-src/wine-mono-10.4.1-src.tar.xz" -C "$L/winemono" -T "$L/winemono/members.txt"
fi
{
    echo "Licences of the projects Wine Mono 10.4.1 is made of (from its source archive, wine-mono-10.4.1-src.tar.xz)."
    echo "Its native parts: the Mono runtime, BoringSSL (libmono-btls-shared), SDL3, FAudio, FNA3D with MojoShader, FNAMF."
    for f in $WMFILES; do
        printf '\n\n==================== %s ====================\n\n' "$f"
        cat "$WM/$f"
    done
} > "$DEST/Wine Mono - component licences.txt"
# Wine's locale and Unicode tables are made from Unicode's data files
[ -f "$L/Unicode-License-v3.txt" ] || curl -fsSL -o "$L/Unicode-License-v3.txt" https://www.unicode.org/license.txt
cp "$L/Unicode-License-v3.txt" "$DEST/Unicode data - Unicode License v3.txt"
if [ ! -f "$L/Apple GPTK License.txt" ]; then
    outer=$(hdiutil attach -nobrowse -readonly "$GPTK_DMG" | grep -o "/Volumes/.*" | head -1)
    inner=$(hdiutil attach -nobrowse -readonly "$outer"/Evaluation*.dmg | grep -o "/Volumes/.*" | head -1)
    textutil -convert txt -stdout "$inner/License.rtf" > "$L/Apple GPTK License.txt"
    textutil -convert txt -stdout "$inner/Acknowledgements.rtf" > "$L/Apple GPTK Acknowledgements.txt"
    hdiutil detach "$inner" >/dev/null; hdiutil detach "$outer" >/dev/null
fi
cp "$L/Apple GPTK License.txt" "$DEST/D3DMetal - Apple Game Porting Toolkit License.txt"
cp "$L/Apple GPTK Acknowledgements.txt" "$DEST/D3DMetal - Acknowledgements.txt"
# Wine Gecko (Wine's Internet Explorer engine): Mozilla's code under the MPL 2.0; the text from its source archive
GECKO_SRC=$HOME/.tessera/build/downloads/redist/wine-gecko-2.47.4-src.tar.xz
[ -f "$L/WineGecko-LICENSE.txt" ] || tar -xJf "$GECKO_SRC" -O wine-gecko-2.47.4/LICENSE > "$L/WineGecko-LICENSE.txt"
cp "$L/WineGecko-LICENSE.txt" "$DEST/Wine Gecko - MPL 2.0.txt"
# OpenAL Soft (runtime/build-openal.sh): LGPL text, PFFFT licence and the HRTF data credit, gathered by the build
cp "$RT/openal/licenses/OpenAL Soft - LGPL 2.0 and notices.txt" "$DEST/OpenAL Soft - LGPL 2.0 and notices.txt"

cat > "$DEST/README.txt" <<'EOF'
Tessera - licences of the software it includes
Tessera's own code: the app, its Steam integration and its game launcher.
Everything below may be redistributed free of charge; D3DMetal only non-commercially (Tessera is free).
Windows runtime (Contents/Resources/Runtime):
  Wine 11.0 ............ GNU LGPL 2.1 or later. Copyright the Wine project authors (see "Wine - authors.txt").
                         Tessera builds it from source with its own changes.
    Libraries Wine builds into its DLLs: Capstone, compiler-rt, FAudio, FluidSynth, GSM 06.10, libjpeg, JPEG XR,
    Little CMS, OpenLDAP, mpg123, musl, libpng, libtiff, LibTomCrypt, vkd3d, libxml2, libxslt, zlib - see
    "Wine - bundled libraries". This software is based in part on the work of the Independent JPEG Group.
    Wine's locale and Unicode tables are made from Unicode's data: Unicode License v3.
  Wine Mono 10.4.1 ..... the .NET runtime Wine uses: MIT, LGPL, MS-PL, zlib, BSD/OpenSSL (BoringSSL) and GPL 2
                         with a linking exception (SharpZipLib) - see the Wine Mono files.
  FreeType ............. FreeType License. Portions of this software are copyright (c) The FreeType Project
                         (www.freetype.org). All rights reserved.
  GnuTLS ............... GNU LGPL 2.1 or later.
  Nettle, GMP .......... GNU LGPL 3 or later (with the GNU GPL 3 text it builds on).
  MoltenVK ............. Apache License 2.0; contains SPIRV-Cross (Apache License 2.0) and cereal (BSD).
  MoltenVK for DXVK .... Apache License 2.0 (same components).
  DXVK 1.10.3 for macOS  zlib licence; OpenVR headers (BSD). Its DLLs contain the MinGW-w64 runtime and LLVM's
                         C++ runtime (see "MinGW-w64 runtime" and "LLVM").
  FFmpeg ............... GNU LGPL 2.1 or later (built without its optional GPL and non-free parts).
  GStreamer ............ GNU LGPL 2.1 or later (core, base, good, ugly, bad and libav plugins Wine uses;
                         the MPEG-PS demuxer is MPL 1.1 or LGPL, used under the LGPL).
  GLib, proxy-libintl .. GNU LGPL 2.1 or later.
  libffi ............... MIT License.   PCRE2 ......... BSD licence.   orc ............ BSD licence.
  DXMT ................. MIT License. Copyright (c) 2023 Feifan He. Contains LLVM (Apache License 2.0 with LLVM
                         exceptions).
  D3DMetal ............. Apple Game Porting Toolkit redistributables, two versions: 4.0 beta 3 (D3DMetal 4.0b3)
                         and 3.0 (D3DMetal 3.0, used on macOS before 26.4 or when a game is set to it). Both
                         included unmodified and distributed free of charge for non-commercial use under Apple's
                         licence (section 2A(iii) and 2C; both packages come with the same licence text, the one
                         included). 4.0's NVIDIA stand-ins (nvapi64.dll, nvngx-on-metalfx.dll) are used only by
                         games set to "DLSS through MetalFX".
  Steam bridge ......... built from the lsteamclient sources of Valve's Proton (BSD licence) with the Steamworks
                         SDK headers Valve publishes with it (see the Steam bridge files).
  Wine Gecko 2.47.4 .... Wine's Internet Explorer engine, made from Mozilla's code: Mozilla Public License 2.0.
  OpenAL Soft 1.25.2 ... GNU LGPL 2.0 or later; contains PFFFT (BSD-style) and HRTF data made from the KEMAR
                         measurements by Bill Gardner and Keith Martin, MIT Media Laboratory.
Not included: Microsoft's Visual C++ runtimes (2005-2022, with MFC), MFC 4.2, parts of DirectX 9.0c (June 2010)
and the Visual Basic 6 runtime. Microsoft's licence does not allow Tessera to ship them; Tessera downloads
Microsoft's own installers from Microsoft's servers on your Mac (the Visual Basic 6 runtime: only its file from
Microsoft's Windows XP SP3 package on the Windows Update servers), checks them against known checksums and installs
them into each game's Windows folder; they are used under Microsoft's licence terms for those packages.
Also not included: Valve's Windows Steam files (steamclient.dll, steamclient64.dll, GameOverlayRenderer64.dll,
Steam.dll, SteamService.exe, iscriptevaluator.exe). The Mac Steam client does not carry them; Tessera downloads
Valve's own package from Valve's update server on your Mac, checks it against its checksum and uses the files
unmodified with your own Steam.
Source code: the complete source of Wine, FreeType, GnuTLS, Nettle, GMP, FFmpeg, GStreamer, GLib, DXVK, OpenAL
Soft and both MoltenVK builds as built for this release, including Tessera's changes and build scripts, is
published as a separate download next to each Tessera release, with the sources of Wine Mono and Wine Gecko.
You may modify these libraries and use your modified versions with Tessera.
EOF
ls "$DEST" | wc -l | tr -d ' '
