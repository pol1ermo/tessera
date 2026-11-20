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
  D3DMetal ............. Apple Game Porting Toolkit redistributables (D3DMetal 3.0), included unmodified and
                         distributed free of charge for non-commercial use under Apple's licence (section 2A(iii)
                         and 2C; the text included is the one of the newest toolkit package, 4.0 beta 3).
  Steam bridge ......... built from the lsteamclient sources of Valve's Proton (BSD licence) with the Steamworks
                         SDK headers Valve publishes with it (see the Steam bridge files).
Source code: the complete source of Wine, FreeType, GnuTLS, Nettle, GMP, FFmpeg, GStreamer, GLib, DXVK and both
MoltenVK builds as built for this release, including Tessera's changes and build scripts, is published as a
separate download next to each Tessera release, with the source of Wine Mono. You may modify these libraries
and use your modified versions with Tessera.
