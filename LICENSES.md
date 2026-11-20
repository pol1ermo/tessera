# Licences

Tessera bundles the software below. The full licence texts are in [`licenses/`](licenses/), inside the app
(`Tessera.app/Contents/Resources/Licenses`) and in `Tessera-licences.zip` next to every release.
All of it may be redistributed free of charge; **D3DMetal only non-commercially**, which is how Tessera is
distributed (it is free).

| Component | Version | Licence | Licence text |
|---|---|---|---|
| **D3DMetal** (Apple Game Porting Toolkit redistributables) | 3.0 | Apple's Game Porting Toolkit licence: distributed unmodified, free of charge, non-commercial only (sections 2A(iii) and 2C) | `D3DMetal - Apple Game Porting Toolkit License.txt`, `D3DMetal - Acknowledgements.txt` |
| **Wine** (with Tessera's changes) | 11.0 | GNU LGPL 2.1 or later | `Wine - LGPL 2.1.txt`, `Wine - authors.txt` |
| Libraries Wine builds into its DLLs: Capstone, compiler-rt, FAudio, FluidSynth, GSM 06.10, libjpeg, JPEG XR, Little CMS, OpenLDAP, mpg123, musl, libpng, libtiff, LibTomCrypt, vkd3d, libxml2, libxslt, zlib | as in Wine 11.0 | each its own (BSD, MIT, zlib, IJG, LGPL, OpenLDAP, libpng, libtiff, public domain) | `Wine - bundled libraries (libjpeg, libpng, libtiff, zlib and others).txt` |
| Unicode data (Wine's locale and Unicode tables) | — | Unicode License v3 | `Unicode data - Unicode License v3.txt` |
| **Wine Mono** (.NET runtime) | 10.4.1 | MIT, LGPL, MS-PL, zlib, BSD/OpenSSL (BoringSSL), GPL 2 with a linking exception (SharpZipLib) | `Wine Mono - licences (LGPL, MIT and others).txt`, `Wine Mono - component licences.txt`, `GNU GPL 2.txt` |
| **DXMT** | 0.80 | MIT | `DXMT - MIT.txt` |
| LLVM (inside DXMT; LLVM's C++ runtime inside DXVK) | — | Apache License 2.0 with LLVM exceptions | `LLVM - Apache 2.0 with LLVM exceptions.txt` |
| **DXVK for macOS** | 1.10.3 | zlib | `DXVK - zlib.txt`, `DXVK - OpenVR headers - BSD.txt` |
| MinGW-w64 runtime (inside DXVK's DLLs) | — | ZPL 2.1, MIT and others (notices) | `MinGW-w64 runtime - licences.txt` |
| **MoltenVK** | 1.4.2 | Apache License 2.0 | `MoltenVK - Apache 2.0.txt` |
| **MoltenVK for DXVK** | 1.2.10 | Apache License 2.0 | `MoltenVK for DXVK - Apache 2.0.txt` |
| SPIRV-Cross, cereal (inside both MoltenVK builds) | — | Apache License 2.0; BSD | `MoltenVK - SPIRV-Cross - Apache 2.0.txt`, `MoltenVK - cereal - BSD.txt` |
| **FreeType** | 2.13.3 | FreeType License | `FreeType - FreeType License.txt` |
| **GnuTLS** | 3.8.3 | GNU LGPL 2.1 or later | `GnuTLS - LGPL 2.1.txt`, `GnuTLS - licensing.txt` |
| **Nettle**, **GMP** | 3.10, 6.3.0 | GNU LGPL 3 or later (with the GNU GPL 3 it builds on) | `Nettle - LGPL 3.txt`, `GMP - LGPL 3.txt`, `GNU GPL 3 (with the LGPL 3 of Nettle and GMP).txt` |
| **FFmpeg** (without its GPL and non-free parts) | 7.1.1 | GNU LGPL 2.1 or later | `FFmpeg - LGPL 2.1.txt`, `FFmpeg - licensing.txt` |
| **GStreamer** (core, base, good, ugly, bad and libav plugins Wine uses) | 1.28.9 | GNU LGPL 2.1 or later (MPEG-PS demuxer: MPL 1.1 or LGPL, used under the LGPL) | `GStreamer - LGPL 2.1.txt` |
| **GLib**, proxy-libintl | 2.86.3, 0.5 | GNU LGPL 2.1 or later | `GLib - LGPL 2.1.txt`, `proxy-libintl - LGPL 2.1.txt` |
| libffi, PCRE2, orc | — | MIT; BSD; BSD | `libffi - MIT.txt`, `PCRE2 - BSD.txt`, `orc - BSD.txt` |
| **Steam bridge** (Valve Proton's lsteamclient, adapted for macOS) | — | BSD 3-clause; Steamworks SDK headers under Valve's SDK licence | `Steam bridge - Proton.txt`, `Steam bridge - Proton license.txt`, `Steam bridge - Steamworks SDK.txt` |
| **Wine Gecko** (Wine's Internet Explorer engine) | 2.47.4 | Mozilla Public License 2.0 | `Wine Gecko - MPL 2.0.txt` |
| **OpenAL Soft** (with PFFFT and HRTF data from MIT's KEMAR measurements) | 1.25.2 | GNU LGPL 2.0 or later; PFFFT BSD-style; KEMAR data free with credit | `OpenAL Soft - LGPL 2.0 and notices.txt` |

**Not included:** Microsoft's Visual C++ runtimes 2005–2022 (with MFC), MFC 4.2 and parts of DirectX 9.0c (June 2010).
Microsoft's licence does not allow Tessera to ship them. From 1.2.9 on, Tessera downloads Microsoft's own installers
from Microsoft's servers on the player's Mac, checks each against a known SHA-256 checksum and installs them into each
game's Windows folder; they are used under Microsoft's licence terms for those packages.

Source code: the LGPL requires the exact sources of Wine, FreeType, GnuTLS, Nettle, GMP, FFmpeg, GStreamer and GLib
as built; they are attached to every release as `tessera-runtime-src-<version>.tar.xz` (with Tessera's changes and
build scripts, the DXVK, MoltenVK and OpenAL Soft sources and the Steam bridge), together with Wine Mono's source from
1.2.7 on and Wine Gecko's from 1.2.9 on.

Which releases contain what: every release has Wine, D3DMetal, DXMT, MoltenVK, FreeType, GnuTLS, Nettle, GMP,
FFmpeg and the Steam bridge; GStreamer, GLib, proxy-libintl, libffi, PCRE2 and orc from 1.2.0; Wine Mono, DXVK,
MoltenVK for DXVK and the MinGW-w64 runtime from 1.2.7; Wine Gecko and OpenAL Soft from 1.2.9.
