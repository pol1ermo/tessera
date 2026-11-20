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
if [ ! -f "$L/Apple GPTK License.txt" ]; then
    outer=$(hdiutil attach -nobrowse -readonly "$GPTK_DMG" | grep -o "/Volumes/.*" | head -1)
    inner=$(hdiutil attach -nobrowse -readonly "$outer"/Evaluation*.dmg | grep -o "/Volumes/.*" | head -1)
    textutil -convert txt -stdout "$inner/License.rtf" > "$L/Apple GPTK License.txt"
    textutil -convert txt -stdout "$inner/Acknowledgements.rtf" > "$L/Apple GPTK Acknowledgements.txt"
    hdiutil detach "$inner" >/dev/null; hdiutil detach "$outer" >/dev/null
fi
cp "$L/Apple GPTK License.txt" "$DEST/D3DMetal - Apple Game Porting Toolkit License.txt"
cp "$L/Apple GPTK Acknowledgements.txt" "$DEST/D3DMetal - Acknowledgements.txt"

cat > "$DEST/README.txt" <<'EOF'
Tessera - licences of the software it includes

Tessera's own code: the app, its Steam integration and its game launcher.

Windows runtime (Contents/Resources/Runtime):

  Wine 11.0 ............ GNU LGPL 2.1 or later. Copyright the Wine project authors (see "Wine - authors.txt").
                         Tessera builds it from source with its own changes.
  FreeType ............. FreeType License. Portions of this software are copyright (c) The FreeType Project
                         (www.freetype.org). All rights reserved.
  GnuTLS ............... GNU LGPL 2.1 or later.
  Nettle, GMP .......... GNU LGPL 3 or later.
  MoltenVK ............. Apache License 2.0.
  FFmpeg ............... GNU LGPL 2.1 or later (built without its optional GPL parts).
  GStreamer ............ GNU LGPL 2.1 or later (core, base, good, ugly, bad and libav plugins Wine uses).
  GLib, proxy-libintl .. GNU LGPL 2.1 or later.
  libffi ............... MIT License.   PCRE2 ......... BSD licence.   orc ............ BSD licence.
  DXMT ................. MIT License. Copyright (c) 2023 Feifan He.
  D3DMetal ............. Apple Game Porting Toolkit redistributables, included unmodified and distributed
                         free of charge for non-commercial use under Apple's licence (see the D3DMetal files).
  Steam bridge ......... built from the lsteamclient sources of Valve's Proton (see the Steam bridge files).

Source code: the complete source of Wine, FreeType, GnuTLS, Nettle, GMP, FFmpeg, GStreamer and GLib as built
for this release,
including Tessera's changes and build scripts, is published as a separate download next to each Tessera
release. You may modify these libraries and use your modified versions with Tessera.
EOF
ls "$DEST" | wc -l | tr -d ' '
