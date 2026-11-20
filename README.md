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

## Licences

Tessera bundles D3DMetal (Apple's Game Porting Toolkit redistributables, included unmodified and distributed free
of charge, non-commercial only), Wine, Wine Mono, DXMT, DXVK, MoltenVK, FreeType, GnuTLS, Nettle, GMP, FFmpeg,
GStreamer, GLib and Valve's Steam bridge code. [LICENSES.md](LICENSES.md) lists every component with its licence;
the texts are in [`licenses/`](licenses/), inside the app (`Tessera.app/Contents/Resources/Licenses`) and in
`Tessera-licences.zip` next to every release. The LGPL libraries' exact sources with Tessera's changes are attached
to every release (`tessera-runtime-src-*.tar.xz`).
