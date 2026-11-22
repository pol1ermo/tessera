# Tessera

**Play Windows games from your Steam library on an Apple silicon Mac — from the normal Mac Steam app.**
Free. One download. Nothing else to install.

Tessera teaches the macOS Steam client to run Windows games: they show **Install** and **Play** in Steam like any Mac
game, they keep Steam features (achievements, friends, cloud saves), and they draw through Apple's Metal graphics.

## Download

Get the newest **Tessera-x.y.z.dmg** from [Releases](../../releases/latest).

Requirements: a Mac with Apple silicon (M1 or newer), macOS 14 Sonoma or later, and [Steam for Mac](https://store.steampowered.com/about/).

## Install

1. Open the disk image and drag **Tessera** into **Applications**.
2. Open Tessera from Applications. The first time, macOS says it can't check Tessera for malware (it is free and not
   registered with Apple): open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
3. Click **Set up in Steam**. macOS asks for your OK the first time: in **Privacy & Security › App Management** turn on
   Tessera, then click **Set up in Steam** again.
4. Steam opens. Install and play your Windows games like any other game.

**Remove from Steam…** (in Tessera) puts Steam's original files and your earlier choices back.

## Updating

From 1.3.0 on, Tessera updates itself. When it opens it asks GitHub whether a newer release is out (once in six
hours at most; the switch is on the same page) and shows it with **Update Now**. It downloads the release's disk image,
checks it against the release's signed update file (size, SHA-256 and a signature only this project's release key can
make), puts the new version in place and opens again. Games, saves and settings stay as they are, Steam does not have
to close, and macOS asks for nothing. **Check for Updates** on Tessera's first page looks at once.

Coming from 1.2.x: download the disk image once more and replace Tessera in Applications; from then on it is one click.

## Licences

Tessera bundles D3DMetal (Apple's Game Porting Toolkit redistributables, included unmodified and distributed free
of charge, non-commercial only), Wine, Wine Mono, Wine Gecko, DXMT, DXVK, MoltenVK, OpenAL Soft, FreeType, GnuTLS,
Nettle, GMP, FFmpeg, GStreamer, GLib and Valve's Steam bridge code. [LICENSES.md](LICENSES.md) lists every component
with its licence; the texts are in [`licenses/`](licenses/), inside the app (`Tessera.app/Contents/Resources/Licenses`)
and in `Tessera-licences.zip` next to every release. The LGPL libraries' exact sources with Tessera's changes are attached
to every release (`tessera-runtime-src-*.tar.xz`). Microsoft's Visual C++ runtimes, MFC, DirectX 2010 parts and the
Visual Basic 6 runtime are not included: Tessera downloads them from Microsoft on your Mac and installs them into each game's Windows folder. Valve's Windows Steam files (steamclient.dll and Steam's script runner), which the Mac Steam client does not carry, come the same way from Valve's update server.
