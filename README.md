# Tessera

**Play Windows games from your Steam library on an Apple silicon Mac — from the normal Mac Steam app.**
Free. One download. Nothing else to install.

Tessera teaches the macOS Steam client to run Windows games: they show **Install** and **Play** in Steam like any Mac
game, they keep Steam features (achievements, friends, cloud saves), and they draw through Apple's Metal graphics.

## Download

Get **Tessera-xx.xx.xx.dmg** from [Releases](../../releases/latest).

Requirements: a Mac with Apple silicon (M1 or newer), macOS 14 Sonoma or later, and [Steam for Mac](https://store.steampowered.com/about/).

## Install

1. Open the disk image and drag **Tessera** into **Applications**.
2. Open Tessera from Applications. The first time, macOS says it can't check Tessera for malware (it is free and not
   registered with Apple): open **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
3. Click **Set up in Steam**. macOS asks for your OK the first time: in **Privacy & Security › App Management** turn on
   Tessera, then click **Set up in Steam** again.
4. Steam opens. Install and play your Windows games like any other game.

**Remove from Steam…** (in Tessera) puts Steam's original files and your earlier choices back.

## How it works

```
Steam.app  ── loads Tessera's library (one start-up setting) ──►  Steam client
   Tessera's library   switches on Steam's own compatibility-tool system (built for Linux, also present on Mac),
                       points it at Tessera, and understands Linux-style launch options ("VAR=1 %command%")
Steam ── "run Game.exe" ──►  Tessera's launcher
   launcher            one Windows folder per game (where Steam Cloud expects it), per-game settings, starts Wine
Windows runtime        Wine 11 (built from source by Tessera) + Apple's D3DMetal + DXMT + MoltenVK
   steam.exe           tells the game Steam is running and starts it
   Steam bridge        Valve's Proton lsteamclient, adapted for the Mac Steam client
```

Graphics: **D3DMetal** (Apple, DirectX 11/12 → Metal) by default; per game you can pick **DXMT** (open source,
DirectX 11 → Metal) or **WineD3D** (older DirectX through OpenGL). Vulkan games run on MoltenVK.

## Tested games (01.00.00)

| Game | Engine | Graphics | Result |
|---|---|---|---|
| R.E.P.O. | Unity | DirectX 11 (D3DMetal, DXMT) | plays, Steam features work |
| Buckshot Roulette | Godot 4 | Vulkan (MoltenVK) | plays |
| The Last of Us Part I | Naughty Dog engine | DirectX 12 (D3DMetal) | starts and runs |
| Counter-Strike: Global Offensive (legacy) | Source, 32-bit | DirectX 9 | **does not start yet** (see known issues) |

## Known issues

- Some 32-bit Source engine games (CS:GO legacy) stop with "Failed to connect with local Steam Client process".
- The Steam overlay (Shift+Tab) is not available inside Windows games yet.
- A game's first start takes a few seconds longer while its Windows folder is created.
- Anti-cheat protected multiplayer games (kernel anti-cheat) do not run.

Report problems in [Issues](../../issues) — attach the game's log (Tessera › the game › **Open Log**).

## Versions

`xx.00.00` major updates · `00.xx.00` improvements · `00.00.xx` bug fixes.

## Building

Everything builds in `~/.tessera/build` (outside iCloud).

```
runtime/build-deps.sh          # FreeType, GMP, Nettle, GnuTLS, FFmpeg (Intel code: Wine runs under Rosetta)
runtime/build-wine.sh          # Wine with Tessera's changes (runtime/patch-wine.py)
bridge/build-bridge.sh         # Steam bridge + steam.exe
runtime/assemble.sh            # -> ~/.tessera/build/rt/out/Runtime
packaging/build-app.sh --dmg   # -> Tessera.app, dist/Tessera.dmg
packaging/check-release.py dist/Tessera.dmg
```

| Folder | What |
|---|---|
| `app/` | Tessera.app (SwiftUI). Also a command line: `Tessera --status / --install / --uninstall` |
| `steampatch/` | the library loaded into Steam (C), with its own arm64 hooking |
| `tool/` | the launcher Steam runs |
| `bridge/` | Steam bridge build and steam.exe |
| `runtime/` | Windows runtime build, assembly and the source archive |
| `packaging/` | app bundle, disk image, licences, release check |

## Licences

Wine, FreeType, GnuTLS, Nettle, GMP and FFmpeg are LGPL — their exact sources with Tessera's changes are attached
to every release (`tessera-runtime-src-*.tar.xz`). D3DMetal is Apple's Game Porting Toolkit redistributable,
included unmodified and distributed free of charge (non-commercial). DXMT is MIT, MoltenVK Apache 2.0, the Steam
bridge comes from Valve's Proton. All licence texts are inside the app: `Tessera.app/Contents/Resources/Licenses`.
