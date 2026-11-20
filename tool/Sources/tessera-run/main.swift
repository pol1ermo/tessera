// tessera-run - the program Steam runs for every Windows game assigned to the Tessera compatibility tool.
//
// Steam calls it as `run <verb> <command...>` (toolmanifest.vdf: "commandline" "/run %verb%"):
//   waitforexitandrun <exe> [args]   start the game, return only when every process of the game has exited
//   run <exe> [args]                 start a helper (install scripts and the like) and wait for it
//   getcompatpath <unix path>        print the Windows path Steam should use for a file
//   getnativepath <windows path>     print the Unix path for a Windows path
// Steam passes the game's context in the environment (STEAM_COMPAT_DATA_PATH, SteamAppId, Steam3Master, ...).
import AppKit
import Darwin
import Foundation

// MARK: - logging

let appID = ProcessInfo.processInfo.environment["SteamAppId"] ?? ProcessInfo.processInfo.environment["STEAM_COMPAT_APP_ID"] ?? "0"
let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tessera")
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
let logURL = logDir.appendingPathComponent("game-\(appID).log")
let logHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    let h = try? FileHandle(forWritingTo: logURL)
    h?.seekToEndOfFile()
    return h
}()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
    let line = "[\(stamp)] \(message)\n"
    logHandle?.write(line.data(using: .utf8)!)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    log("ERROR: \(message)")
    FileHandle.standardError.write("tessera: \(message)\n".data(using: .utf8)!)
    exit(code)
}

// MARK: - runtime

/// The Wine runtime Tessera ships: inside the app when installed, overridable for development.
struct Runtime {
    let root: URL
    var loader: URL { root.appendingPathComponent("bin/wineloader") }
    var server: URL { root.appendingPathComponent("bin/wineserver") }
    var starter: String { "C:\\windows\\system32\\start.exe" }

    static func locate(env: [String: String]) -> Runtime {
        if let path = env["TESSERA_RUNTIME"], !path.isEmpty { return Runtime(root: URL(fileURLWithPath: path)) }
        // installed: Tessera.app keeps a link to its runtime in its Application Support folder
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tessera/runtime").resolvingSymlinksInPath()
        if FileManager.default.isExecutableFile(atPath: installed.appendingPathComponent("bin/wineloader").path) {
            return Runtime(root: installed)
        }
        // Tessera.app was moved since setup (the link points at its old place): find it again and fix the link
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tessera/runtime")
        for app in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.polermo.tessera2") {
            let moved = app.appendingPathComponent("Contents/Resources/Runtime")
            guard FileManager.default.isExecutableFile(atPath: moved.appendingPathComponent("bin/wineloader").path) else { continue }
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
            return Runtime(root: moved)
        }
        // the tool lives at <Tessera.app>/Contents/Resources/compat/tessera/run inside a release build
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundled = me.deletingLastPathComponent().appendingPathComponent("../../Runtime").standardized
        if FileManager.default.isExecutableFile(atPath: bundled.appendingPathComponent("bin/wineloader").path) {
            return Runtime(root: bundled)
        }
        let dev = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tessera/Runtimes/wine-11.0-tessera-20260907")
        return Runtime(root: dev)
    }
}

// MARK: - environment

let steamEnv = ProcessInfo.processInfo.environment
let runtime = Runtime.locate(env: steamEnv)
guard FileManager.default.isExecutableFile(atPath: runtime.loader.path) else {
    fail("the Wine runtime is missing at \(runtime.root.path)")
}

func prefixURL() -> URL {
    guard let data = steamEnv["STEAM_COMPAT_DATA_PATH"], !data.isEmpty else {
        fail("Steam did not pass STEAM_COMPAT_DATA_PATH")
    }
    // Steam keeps cloud saves of Windows games at <compatdata>/pfx/drive_c/users/steamuser/... (the paths are built
    // into the Steam client), so that is where the Windows folder lives. A pfx some other tool made is left alone:
    // Tessera then uses a folder of its own next to it.
    let compat = URL(fileURLWithPath: data)
    let pfx = compat.appendingPathComponent("pfx")
    let fm = FileManager.default
    if !fm.fileExists(atPath: pfx.path) || fm.fileExists(atPath: pfx.appendingPathComponent(".tessera").path) {
        return pfx
    }
    return compat.appendingPathComponent("tessera")
}

func wineEnvironment(prefix: URL, exe: String) -> [String: String] {
    var env = steamEnv
    let root = runtime.root.path
    env["WINEPREFIX"] = prefix.path
    env["WINELOADER"] = runtime.loader.path
    env["WINESERVER"] = runtime.server.path
    // the Steam bridge has its own folder, so nothing outside Tessera's launcher ever sees a builtin steamclient
    env["WINEDLLPATH"] = "\(root)/lib/tessera-steam"
    env["DYLD_LIBRARY_PATH"] = "\(root)/lib64"
    env["TESSERA_ROOT"] = root                 // the runtime's macOS code finds icons and helpers through it
    env["WINEMSYNC"] = env["WINEMSYNC"] ?? "1"
    // Rosetta reports AVX/AVX2 only when asked; many current games need them (some launchers silently pick a
    // fallback or quit without). A game's settings can turn it off with ROSETTA_ADVERTISE_AVX=0.
    env["ROSETTA_ADVERTISE_AVX"] = env["ROSETTA_ADVERTISE_AVX"] ?? "1"
    // Vulkan games (MoltenVK): subgroup operations only in compute shaders. In a Metal fragment function an elected
    // "first" thread can be a helper thread whose writes Metal drops - Godot 4's clustered lights then lose lights per
    // screen tile (black squares in Buckshot Roulette). A game's settings can turn it back with ...=1.
    env["MVK_CONFIG_FRAGMENT_SUBGROUPS"] = env["MVK_CONFIG_FRAGMENT_SUBGROUPS"] ?? "0"
    env["WINEDEBUG"] = env["WINEDEBUG"] ?? "-all"
    // GStreamer (winegstreamer: game videos and sound through Windows Media, Media Foundation, DirectShow) loads
    // only the runtime's own plugins - never a GStreamer installed on the Mac - and keeps its plugin index in
    // Tessera's cache folder. The index is built inside the game's process (no separate scanner program).
    let gstPlugins = "\(root)/lib64/gstreamer-1.0"
    if FileManager.default.fileExists(atPath: gstPlugins) {
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = gstPlugins
        env["GST_PLUGIN_PATH_1_0"] = ""
        env.removeValue(forKey: "GST_PLUGIN_PATH")
        env.removeValue(forKey: "GST_PLUGIN_SCANNER_1_0")
        env["GST_REGISTRY_FORK"] = "no"
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Tessera")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        env["GST_REGISTRY_1_0"] = cache.appendingPathComponent("gstreamer-registry.bin").path
    }
    // Per-game settings: ~/Library/Application Support/Tessera/games/<appid>.env, one NAME=value per line ("#" comments).
    let settings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tessera/games/\(appID).env")
    if let text = try? String(contentsOf: settings, encoding: .utf8) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        log("per-game settings from \(settings.lastPathComponent)")
    }
    // .NET Framework programs (launchers, tools) run on Wine Mono, which the runtime carries (share/wine/mono), so
    // Wine never asks to download it; no Gecko (Internet Explorer engine) installer prompts
    // winemenubuilder off: it would put shortcut apps into ~/Applications when games install
    // Microsoft's C++ runtime: Steam installs it into the Windows folder on a game's first start (its redistributable
    // step), as on Windows, and newer games accept only that version (Unreal 5's starter refused Wine's 14.42 copy:
    // "Microsoft Visual C++ 2015-2022 Redistributable (x64) is required"). The installed files go first; without them
    // Wine's own copies load.
    // A game's own WINEDLLOVERRIDES (settings above) comes last, so it adds to these instead of replacing them.
    let msvcRuntime = "msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,msvcp140_codecvt_ids,vcruntime140,vcruntime140_1,concrt140=n,b"
    // winedbg off: a crashed game closes (Wine's crash debugger kept crashed programs open for good - Steam still showed
    // them running); the log keeps Wine's "Unhandled page fault ..." line with the crash address.
    let overrides = ["mshtml=d", "winemenubuilder.exe=d", "winedbg.exe=d", "steam.exe=b", msvcRuntime,
                     env["WINEDLLOVERRIDES"]].compactMap { $0 }.filter { !$0.isEmpty }
    env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
    // The app's graphics choice, translated to the runtime's backend folder (D3DMetal is the runtime's default).
    // Automatic (no choice in the game's settings): D3DMetal, except for engines D3DMetal is known to trip up.
    var graphics = env["TESSERA_GRAPHICS"] ?? "d3dmetal"
    if env["TESSERA_GRAPHICS"] == nil, let game = gameNeedingDXVK(exe: exe, env: env) {
        graphics = "dxvk"
        log("\(game): graphics through DXVK (automatic choice)")
    } else if env["TESSERA_GRAPHICS"] == nil, let engine = engineNeedingDXMT(exe: exe, env: env) {
        graphics = "dxmt"
        log("\(engine) game: graphics through DXMT (automatic choice)")
    }
    // A game drawing through D3DMetal starts on a desktop as big as the screen's largest real mode (Tessera's Wine
    // reads TESSERA_FULL_RESOLUTION): Apple's DXGI lists display modes only up to the desktop size, so the game opens
    // at full resolution and its menu offers every size. DXMT, WineD3D, Vulkan and OpenGL list every mode on the Mac
    // desktop size, and Chromium-based games draw magnified on a larger emulated desktop (OpenGL itself is scaled
    // correctly), so those keep the Mac size, as do 32-bit programs (D3DMetal is 64-bit only) and programs that link only
    // Direct3D 9, OpenGL or Vulkan; a 32-bit or .NET launcher whose game folder holds a 64-bit DXGI program gets the
    // full size for that game. A game's settings can say TESSERA_FULL_RESOLUTION=0 or 1.
    // Steam's own helpers (the install-script runner before each start) use the game's choice, remembered in its
    // Windows folder, so the game does not inherit a desktop size chosen for a helper.
    if env["TESSERA_FULL_RESOLUTION"] == nil {
        let gameChoice = prefix.appendingPathComponent(".tessera-desktop-game")
        let full: Bool
        if isSteamHelper(exe) {
            full = (try? String(contentsOf: gameChoice, encoding: .utf8)) == "full"
        } else {
            full = graphics == "d3dmetal" && !isChromiumBased(exe: exe)
                && (mayUseDXGI(exe: exe) || startsDXGIProgram(exe: exe))
            // (a game's first program may run before its Windows folder exists)
            try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            try? (full ? "full" : "mac").write(to: gameChoice, atomically: true, encoding: .utf8)
        }
        env["TESSERA_FULL_RESOLUTION"] = full ? "1" : "0"
    }
    switch graphics {
    case "dxmt": env["TESSERA_BACKEND_DIR"] = "\(root)/lib/dxmt"
    case "wined3d": env["TESSERA_BACKEND_DIR"] = "\(root)/lib/wined3d"
    case "dxvk":
        // CodeWeavers' DXVK, with the MoltenVK it is made for: Wine loads the Vulkan library this variable names
        // (patch-wine.py 4x); DYLD_LIBRARY_PATH cannot do it, macOS ignores it for Wine's signed loader
        env["TESSERA_BACKEND_DIR"] = "\(root)/lib/dxvk"
        env["TESSERA_LIBVULKAN"] = "\(root)/lib64/dxvk/libMoltenVK.dylib"
    default: env.removeValue(forKey: "TESSERA_BACKEND_DIR")
    }
    env["TESSERA_ACTIVE_GRAPHICS_BACKEND"] = graphics
    if graphics == "d3dmetal" {
        // Apple's D3DMetal helper is loaded into every process: it registers the native code D3DMetal runs
        // inside the Intel (Rosetta) process, so Wine's exception handling knows about it
        env["TESSERA_APPLEGPTK_LIBD3DSHARED_PATH"] = "\(root)/lib64/apple_gptk/external/libd3dshared.dylib"
    }
    // Steam's overlay (Shift+Tab): Steam names its libraries in STEAM_DYLD_INSERT_LIBRARIES; Tessera's Wine puts them
    // into each Windows program (TESSERA_OVERLAY_DYLIBS). On unless a game's settings say TESSERA_STEAM_OVERLAY=0.
    // Steam's DYLD_INSERT_LIBRARIES itself (with Tessera's Steam library) is not for games.
    env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
    if env["TESSERA_STEAM_OVERLAY"] != "0", let overlay = steamEnv["STEAM_DYLD_INSERT_LIBRARIES"], !overlay.isEmpty {
        env["TESSERA_OVERLAY_DYLIBS"] = overlay
    }
    return env
}

/// The Elder Scrolls V: Skyrim Special Edition crashes in its own code under both Metal translations of Direct3D 11
/// (D3DMetal and DXMT: an access violation about 12 s in, at the intro video and again at New Game; CrossOver users see
/// the same with D3DMetal) and runs on DXVK. Steam starts its launcher, whose game process inherits the choice. The
/// game's settings can turn this off with TESSERA_ENGINE_SWITCHES=0.
func gameNeedingDXVK(exe: String, env: [String: String]) -> String? {
    guard env["TESSERA_ENGINE_SWITCHES"] != "0" else { return nil }
    let name = URL(fileURLWithPath: exe).lastPathComponent.lowercased()
    return ["skyrimse.exe", "skyrimselauncher.exe"].contains(name) ? "Skyrim Special Edition" : nil
}

/// GameMaker's DirectX 11 runner asks for 8x and 16x anti-aliasing levels; D3DMetal answers "invalid argument"
/// (Windows and DXMT answer "no quality levels") and the game shows an error box for each answer before it starts.
/// GameMaker games keep their game data in data.win next to the program.
/// 32-bit Direct3D 10/11 programs get DXMT too (see uses32BitDirect3D11).
/// BeamNG's engine gets its Direct3D 11 renderer from Tessera (see beamNGRendererArgs); DXMT runs that renderer
/// faster than D3DMetal and lists every resolution the screen has.
func engineNeedingDXMT(exe: String, env: [String: String]) -> String? {
    let dir = URL(fileURLWithPath: exe).deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("data.win").path) { return "GameMaker" }
    if !beamNGRendererArgs(exe: exe, env: env).isEmpty { return "BeamNG" }
    if uses32BitDirect3D11(exe: exe) { return "32-bit Direct3D 11" }
    return nil
}

/// D3DMetal is 64-bit only, so a 32-bit program's Direct3D 10/11 would fall back to Wine's own, which cannot create a
/// device on macOS's OpenGL (Unity: "Failed to initialize graphics"); DXMT has a 32-bit build. True for 32-bit
/// programs that link or delay-load Direct3D 10/11 and for 32-bit Unity games (Unity 5 and later draw through
/// Direct3D 11; Unity 4's Direct3D 9 keeps Wine's own, as DXMT has no Direct3D 9). .NET launchers are left alone.
func uses32BitDirect3D11(exe: String) -> Bool {
    guard let main = peImports(exe), !main.is64, !main.dotNet else { return false }
    let d3d11: Set<String> = ["d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d11.dll"]
    return !main.dlls.union(main.delayed).isDisjoint(with: d3d11) || isUnityGame(exe: exe)
}

/// Programs Steam runs from its own folder in a game's Windows folder (the install-script runner, the Steam service).
func isSteamHelper(_ exe: String) -> Bool {
    let name = URL(fileURLWithPath: exe).lastPathComponent.lowercased()
    return exe.contains("/Steam.AppBundle/") || name == "iscriptevaluator.exe" || name == "steamservice.exe"
}

/// What a Windows program links: whether it is 64-bit, whether it is a .NET program (its code is then not in the
/// import table), the DLLs it links and those it delay-loads (loaded on first use; engines list optional renderers
/// there); nil when it is not a PE file. Reads only the headers and those tables.
func peImports(_ path: String) -> (is64: Bool, dotNet: Bool, dlls: Set<String>, delayed: Set<String>)? {
    guard let h = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? h.close() }
    func read(_ offset: Int, _ count: Int) -> [UInt8] {
        guard offset >= 0, (try? h.seek(toOffset: UInt64(offset))) != nil,
              let d = try? h.read(upToCount: count) else { return [] }
        return [UInt8](d)
    }
    func u16(_ b: [UInt8], _ o: Int) -> Int { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
    func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }
    let head = read(0, 64 << 10)                    // DOS and PE headers with the section table
    guard head.count > 0x40, head[0] == 0x4d, head[1] == 0x5a else { return nil }
    let pe = u32(head, 0x3c)
    guard u32(head, pe) == 0x4550 else { return nil }
    let sections = min(u16(head, pe + 6), 96), optSize = u16(head, pe + 20), opt = pe + 24
    let is64 = u16(head, opt) == 0x20b
    let dirCount = u32(head, opt + (is64 ? 108 : 92)), dirs = opt + (is64 ? 112 : 96)
    func directory(_ i: Int) -> Int { i < dirCount ? u32(head, dirs + i * 8) : 0 }   // 1 imports, 13 delay-load, 14 .NET
    func offset(_ rva: Int) -> Int? {
        for i in 0..<sections {
            let sh = opt + optSize + i * 40
            let va = u32(head, sh + 12), size = max(u32(head, sh + 8), u32(head, sh + 16)), raw = u32(head, sh + 20)
            if rva >= va && rva < va + size { return rva - va + raw }
        }
        return nil
    }
    func names(_ index: Int, entrySize: Int, nameAt: Int) -> Set<String> {
        var dlls = Set<String>()
        let rva = directory(index)
        guard rva != 0, let start = offset(rva) else { return dlls }
        let table = read(start, entrySize * 256)
        var d = 0
        while d + entrySize <= table.count, u32(table, d + nameAt) != 0 {
            if let n = offset(u32(table, d + nameAt)) {
                let raw = read(n, 128)
                let end = raw.firstIndex(of: 0) ?? raw.count
                dlls.insert(String(decoding: raw[..<end], as: UTF8.self).lowercased())
            }
            d += entrySize
        }
        return dlls
    }
    return (is64, directory(14) != 0, names(1, entrySize: 20, nameAt: 12), names(13, entrySize: 32, nameAt: 4))
}

/// The DLLs of DXGI and Direct3D 10-12.
let dxgiDLLs: Set<String> = ["dxgi.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll"]

/// Unity games keep their player in UnityPlayer.dll (Unity 2017.2 and later) or their data in <program>_Data. Unity's
/// Windows default renderer is Direct3D 11, which the player loads at run time (it links only its optional OpenGL one).
func isUnityGame(exe: String) -> Bool {
    let url = URL(fileURLWithPath: exe), dir = url.deletingLastPathComponent(), fm = FileManager.default
    return fm.fileExists(atPath: dir.appendingPathComponent("UnityPlayer.dll").path)
        || fm.fileExists(atPath: dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_Data").path)
}

/// Whether a game may draw through DXGI (Direct3D 10-12), the only path whose resolution list stops at the desktop.
/// Yes for Unity games and programs that link or delay-load DXGI or Direct3D 10-12. No for 32-bit programs (D3DMetal
/// is 64-bit only), for programs that link Direct3D 8/9 or OpenGL, and for Vulkan programs: those list every mode on
/// the Mac desktop. Otherwise yes: engines that load their renderer later (an Unreal start program) may pick
/// Direct3D 12.
func mayUseDXGI(exe: String) -> Bool {
    guard let main = peImports(exe) else { return true }
    if !main.is64 { return false }
    if isUnityGame(exe: exe) { return true }
    let all = main.dlls.union(main.delayed)
    if !all.isDisjoint(with: dxgiDLLs) { return true }
    return main.dlls.isDisjoint(with: ["d3d9.dll", "d3d8.dll", "opengl32.dll"]) && !all.contains("vulkan-1.dll")
}

/// The Steam game folder a program belongs to (<library>/steamapps/common/<game>), else the program's own folder.
func gameFolder(of exe: String) -> URL {
    let url = URL(fileURLWithPath: exe)
    let parts = url.pathComponents
    if let i = parts.lastIndex(where: { $0.lowercased() == "common" }), i > 0,
       parts[i - 1].lowercased() == "steamapps", i + 2 < parts.count {
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts[...(i + 1)])))
    }
    return url.deletingLastPathComponent()
}

/// A 32-bit or .NET program (often a game's launcher) starts a game that needs the full-resolution desktop when its
/// game folder holds a 64-bit Unity game or a 64-bit program linking or delay-loading DXGI or Direct3D 10-12.
/// Installers, redistributables and crash reporters are skipped.
func startsDXGIProgram(exe: String) -> Bool {
    guard let main = peImports(exe), !main.is64 || main.dotNet else { return false }
    let skip = ["redist", "vcredist", "vc_redist", "directx", "dxsetup", "dotnet", "ndp4", "oalinst", "physx", "prereq",
                "setup", "unins", "install", "crashhandler", "crashreport", "easyanticheat", "battleye"]
    guard let walker = FileManager.default.enumerator(at: gameFolder(of: exe), includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return false }
    var checked = 0
    for case let url as URL in walker {
        let name = url.lastPathComponent.lowercased()
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if walker.level >= 4 || skip.contains(where: { name.contains($0) }) { walker.skipDescendants() }
            continue
        }
        guard name.hasSuffix(".exe"), !skip.contains(where: { name.contains($0) }), url.path != exe else { continue }
        checked += 1
        if checked > 64 { break }
        guard let program = peImports(url.path), program.is64 else { continue }
        if isUnityGame(exe: url.path) || !program.dlls.union(program.delayed).isDisjoint(with: dxgiDLLs) { return true }
    }
    return false
}

/// Chromium-based games (NW.js, e.g. RPG Maker MV/MZ; CEF) ship nw.dll or libcef.dll next to the program or one
/// folder up. On a desktop larger than the screen they draw their page magnified and cut off (about 1.7x, the
/// desktop's scale), while plain OpenGL, Vulkan and Metal windows are scaled correctly.
func isChromiumBased(exe: String) -> Bool {
    let dir = URL(fileURLWithPath: exe).deletingLastPathComponent()
    return ["nw.dll", "libcef.dll"].contains { name in
        [dir, dir.deletingLastPathComponent()].contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } }
}

/// BeamNG's engine (BeamNG.drive, BeamNG.tech) starts its Direct3D 12 renderer by default. D3DMetal refuses the
/// indirect-draw command signature that renderer builds for its GPU-driven drawing (CreateCommandSignature returns
/// E_INVALIDARG); the engine asks again every frame and draws the scene without that geometry, and with GPU-driven
/// drawing turned off the scene still comes out washed out. Its Direct3D 11 renderer draws correctly.
/// Returns the arguments that pick it, unless the game's arguments already choose a renderer (-gfx) or the game's
/// settings say TESSERA_ENGINE_SWITCHES=0.
func beamNGRendererArgs(exe: String, env: [String: String]) -> [String] {
    guard URL(fileURLWithPath: exe).lastPathComponent.lowercased().hasPrefix("beamng."),
          env["TESSERA_ENGINE_SWITCHES"] != "0" else { return [] }
    let given = Array(CommandLine.arguments.dropFirst(3)) + (env["TESSERA_GAME_ARGS"] ?? "").split(separator: " ").map(String.init)
    return given.contains(where: { $0.lowercased() == "-gfx" }) ? [] : ["-gfx", "dx11"]
}

// MARK: - processes

@discardableResult
func runProcess(_ exe: URL, _ args: [String], env: [String: String], cwd: URL? = nil, wait: Bool = true) -> Int32 {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.environment = env
    if let cwd = cwd { p.currentDirectoryURL = cwd }
    p.standardOutput = logHandle
    p.standardError = logHandle
    do { try p.run() } catch { log("could not start \(exe.path): \(error)"); return -1 }
    if wait { p.waitUntilExit() }
    return wait ? p.terminationStatus : 0
}

/// Wine runs Intel code through Apple's Rosetta 2. Apple-silicon Macs do not have it until something asks for it, and
/// Steam runs natively, so a Mac can have Steam and Tessera without Rosetta: then every Windows program fails to start
/// ("Bad CPU type"), whatever the graphics. When it is missing, Tessera asks and installs it with Apple's
/// softwareupdate (no administrator password needed). TESSERA_TEST_NO_ROSETTA=1 pretends it is missing (testing).
func rosettaInstalled() -> Bool {
    ProcessInfo.processInfo.environment["TESSERA_TEST_NO_ROSETTA"] != "1"
        && FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
}

func ensureRosetta() {
    guard !rosettaInstalled() else { return }
    log("Rosetta 2 is not installed: Windows programs run through it")
    let ask = Process()
    ask.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    ask.arguments = ["-e", "display dialog \"Windows games need Apple's Rosetta 2, which is not installed on this Mac yet. Install it now? (About a minute; by installing you agree to Apple's licence for Rosetta.)\" buttons {\"Not Now\", \"Install Rosetta\"} default button 2 with title \"Tessera\" with icon caution"]
    let pipe = Pipe(); ask.standardOutput = pipe; ask.standardError = pipe
    try? ask.run(); ask.waitUntilExit()
    let answer = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard answer.contains("Install Rosetta") else { fail("Rosetta 2 is not installed; the game cannot start without it") }
    log("installing Rosetta 2")
    let status = runProcess(URL(fileURLWithPath: "/usr/sbin/softwareupdate"), ["--install-rosetta", "--agree-to-license"], env: ProcessInfo.processInfo.environment)
    guard status == 0, FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") else {
        fail("installing Rosetta 2 failed (softwareupdate exit \(status))")
    }
    log("Rosetta 2 installed")
}

func killPrefix(_ env: [String: String]) {
    runProcess(runtime.server, ["-k"], env: env)
}

// MARK: - prefix

// Wine's first set-up of a Windows folder takes 12-16 s. Tessera does it once per runtime, keeps the result as a
// template and gives every new game an APFS clone of it (copy-on-write: instant, no extra space).
let templatesDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Tessera/templates")

func buildPrefix(_ dir: URL, env: [String: String]) {
    var e = env
    e["WINEPREFIX"] = dir.path
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    runProcess(runtime.loader, ["wineboot", "--init"], env: e)
    // wineserver writes the registry when it exits, so wait for it before anything reads the folder
    runProcess(runtime.server, ["-w"], env: e)
}

/// FNV-1a: a name that stays the same between runs (Swift's Hasher changes per process)
func stableHash(_ text: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

/// The template for this runtime, named after the runtime's place, its wine.inf (Wine compares that file to tell
/// whether a Windows folder is current) and its Wine Mono; built on first use, earlier runtimes' templates are removed.
func prefixTemplate(env: [String: String]) -> URL? {
    let fm = FileManager.default
    let inf = runtime.root.appendingPathComponent("share/wine/wine.inf")
    guard let attrs = try? fm.attributesOfItem(atPath: inf.path),
          let changed = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
    // Wine Mono in the runtime (share/wine/mono) changes what Wine's set-up installs (.NET support), so it is part of it
    let mono = ((try? fm.contentsOfDirectory(atPath: runtime.root.appendingPathComponent("share/wine/mono").path)) ?? [])
        .sorted().joined(separator: ",")
    let key = stableHash("\(runtime.root.path)|\(Int(changed))|\(attrs[.size] ?? 0)|\(mono)")
    let template = templatesDir.appendingPathComponent(key)
    let ready = { fm.fileExists(atPath: template.appendingPathComponent("system.reg").path) }
    if ready() { return template }
    log("building the Windows folder template (once per Tessera version)")
    // built under a temporary name, so two games starting at once never clone a half-built one
    let building = templatesDir.appendingPathComponent("\(key).building-\(getpid())")
    try? fm.removeItem(at: building)
    buildPrefix(building, env: env)
    if fm.fileExists(atPath: building.appendingPathComponent("system.reg").path), !ready() {
        try? fm.moveItem(at: building, to: template)
    }
    try? fm.removeItem(at: building)
    for old in (try? fm.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil)) ?? []
    where old.lastPathComponent != key && !old.lastPathComponent.contains(".building-") {
        try? fm.removeItem(at: old)
    }
    return ready() ? template : nil
}

func ensurePrefix(_ prefix: URL, env: [String: String]) {
    let fm = FileManager.default
    if fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) { return }
    log("creating prefix \(prefix.path)")
    let started = Date()
    var cloned = false
    if let template = prefixTemplate(env: env) {
        try? fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        // -c clones on APFS (cp copies normally where it can't, e.g. a Steam library on another disk)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-cpR", template.path + "/.", prefix.path + "/"]
        var copied = false
        if (try? cp.run()) != nil { cp.waitUntilExit(); copied = cp.terminationStatus == 0 }
        cloned = copied && fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
        if !cloned { log("could not copy the template; setting the folder up directly") }
    }
    if !cloned { buildPrefix(prefix, env: env) }
    fm.createFile(atPath: prefix.appendingPathComponent(".tessera").path, contents: Data("made by Tessera\n".utf8))
    log("prefix ready after \(Int(Date().timeIntervalSince(started))) s\(cloned ? " (from the template)" : "")")
}

// MARK: - path conversion (Steam asks for these when it runs install scripts)

func windowsPath(forUnix path: String) -> String {
    // Wine maps Z: to /, so every Unix path has a Windows spelling without asking Wine.
    "Z:" + path.replacingOccurrences(of: "/", with: "\\")
}

func unixPath(forWindows path: String, prefix: URL) -> String {
    var p = path.replacingOccurrences(of: "\\", with: "/")
    if p.count >= 2, p[p.index(p.startIndex, offsetBy: 1)] == ":" {
        let drive = p.prefix(1).lowercased()
        p = String(p.dropFirst(2))
        if drive == "z" { return p }
        return prefix.appendingPathComponent("dosdevices/\(drive):").path + p
    }
    return p
}

// MARK: - main

var args = Array(CommandLine.arguments.dropFirst())
guard let verb = args.first else { fail("no verb (Steam calls: run <verb> <command>)") }
args.removeFirst()
log("=== \(verb) \(args.joined(separator: " "))")

switch verb {
case "getcompatpath":
    print(windowsPath(forUnix: args.first ?? ""))
    exit(0)
case "getnativepath":
    print(unixPath(forWindows: args.first ?? "", prefix: prefixURL()))
    exit(0)
case "waitforexitandrun", "run":
    break
default:
    fail("unknown verb \(verb)")
}

guard let exePath = args.first else { fail("no program to run") }
let gameArgs = Array(args.dropFirst())
ensureRosetta()
let prefix = prefixURL()
let env = wineEnvironment(prefix: prefix, exe: exePath)
// A Wine session still running in this Windows folder keeps its desktop size. Steam's install-script runner ends a
// moment before the game starts; when the game needs the other size, that lingering session is ended first. A
// session of a game itself is never ended (a second program shares its desktop).
let desktopMarker = prefix.appendingPathComponent(".tessera-desktop")
let desktopSize = env["TESSERA_FULL_RESOLUTION"] == "1" ? "full" : "mac"
if let previous = try? String(contentsOf: desktopMarker, encoding: .utf8) {
    let parts = previous.split(separator: " ").map(String.init)
    if parts.first != desktopSize && parts.count > 1 && parts[1] == "helper" {
        killPrefix(env)
        log("desktop size \(parts[0]) -> \(desktopSize): ended the lingering Wine session of Steam's helper first")
    }
}
ensurePrefix(prefix, env: env)
try? (desktopSize + (isSteamHelper(exePath) ? " helper" : "")).write(to: desktopMarker, atomically: true, encoding: .utf8)

// Steam's Stop button and quitting Steam end this process; take the game's processes down with it.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    src.setEventHandler {
        log("signal \(sig): stopping the game")
        killPrefix(env)
        exit(128 + sig)
    }
    src.resume()
    signalSources.append(src)
}

// MARK: Steam bridge in the prefix
// steam_api(64).dll looks for steamclient(64).dll where the registry says Steam is installed; the copies there only
// need to exist - Wine sees they are builtins and loads the bridge from the runtime. steam.exe registers itself as
// the running Steam and starts the game.
/// Copies a file unless an identical-size copy is already there.
func stageFile(_ from: URL, _ to: URL) {
    let fm = FileManager.default
    let fromSize = (try? fm.attributesOfItem(atPath: from.path)[.size] as? Int) ?? -1
    let toSize = (try? fm.attributesOfItem(atPath: to.path)[.size] as? Int) ?? -2
    guard fromSize != toSize else { return }
    try? fm.removeItem(at: to)
    do { try fm.copyItem(at: from, to: to) } catch { log("could not stage \(to.lastPathComponent): \(error)") }
}

/// Wine loads a built-in DLL only when the Windows system folder has a file of that name (made by wineboot for
/// Wine's own DLLs). The graphics backends bring DLLs Wine does not have, so those get their placeholder here; Wine
/// then loads the real one from TESSERA_BACKEND_DIR.
func stageBackend(_ prefix: URL, backendDir: String?) {
    guard let dir = backendDir else { return }
    let fm = FileManager.default
    let backend = URL(fileURLWithPath: dir)
    let windows = prefix.appendingPathComponent("drive_c/windows")
    for (arch, sysdir) in [("x86_64-windows", "system32"), ("i386-windows", "syswow64")] {
        let src = backend.appendingPathComponent(arch)
        guard let names = try? fm.contentsOfDirectory(atPath: src.path) else { continue }
        // never NVIDIA's names: a placeholder would outlive the backend choice, and games that find nvapi64
        // assume an NVIDIA card (Chromium-based launchers also stall on it)
        for name in names where name.lowercased().hasSuffix(".dll") && !name.lowercased().hasPrefix("nv") {
            let target = windows.appendingPathComponent(sysdir).appendingPathComponent(name)
            if !fm.fileExists(atPath: target.path) { stageFile(src.appendingPathComponent(name), target) }
        }
    }
}

/// Steam passes the client's program folder (…/Steam.AppBundle/Steam/Contents/MacOS) as STEAM_COMPAT_CLIENT_INSTALL_PATH;
/// the Steam root with steamapps is four levels up.
func steamClientFolders() -> (root: URL, binaries: URL) {
    let fm = FileManager.default
    let fallbackRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    guard let given = steamEnv["STEAM_COMPAT_CLIENT_INSTALL_PATH"], !given.isEmpty else {
        return (fallbackRoot, fallbackRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS"))
    }
    let url = URL(fileURLWithPath: given).standardized
    if url.path.hasSuffix("/Contents/MacOS") {
        let root = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (fm.fileExists(atPath: root.appendingPathComponent("steamapps").path) ? root : fallbackRoot, url)
    }
    return (url, url.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS"))
}

func writeLibraryFolders(steamDir: URL, client: URL) {
    var libraries = [client.path]
    if let text = try? String(contentsOf: client.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
        let re = try! NSRegularExpression(pattern: "\"path\"\\s*\"([^\"]+)\"")
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            if !libraries.contains(path) { libraries.append(path) }
        }
    }
    func vdfEscape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\") }
    var vdf = "\"libraryfolders\"\n{\n\t\"0\"\n\t{\n\t\t\"path\"\t\t\"C:\\\\Program Files (x86)\\\\Steam\"\n\t}\n"
    for (i, lib) in libraries.enumerated() {
        vdf += "\t\"\(i + 1)\"\n\t{\n\t\t\"path\"\t\t\"\(vdfEscape(windowsPath(forUnix: lib)))\"\n\t}\n"
    }
    vdf += "}\n"
    let dir = steamDir.appendingPathComponent("steamapps")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? vdf.write(to: dir.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)
}

func stageSteam(_ prefix: URL) -> URL {
    let fm = FileManager.default
    let bridge = runtime.root.appendingPathComponent("lib/tessera-steam")
    let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    try? fm.createDirectory(at: steamDir, withIntermediateDirectories: true)
    // The Steam folder gets Valve's real Windows files, which the Mac Steam client ships for this purpose
    // (legacycompat): some games check that steamclient.dll carries Valve's signature before loading it. Tessera's
    // Wine loads the bridge (lsteamclient) whenever a game loads steamclient, so the real ones never run.
    let client = steamClientFolders()
    let legacy = client.binaries.appendingPathComponent("legacycompat")
    for name in ["steamclient.dll", "steamclient64.dll", "Steam.dll"] {
        let real = legacy.appendingPathComponent(name)
        if fm.fileExists(atPath: real.path) {
            stageFile(real, steamDir.appendingPathComponent(name))
            // Steam's oldest DRM wrapper (2000s games: Hitman 2, Hitman: Codename 47) loads steam.dll by name only,
            // which Windows finds in the system folder; Steam.dll is 32-bit, so it goes to the 32-bit one
            let wow64 = prefix.appendingPathComponent("drive_c/windows/syswow64")
            if name == "Steam.dll" && fm.fileExists(atPath: wow64.path) {
                stageFile(real, wow64.appendingPathComponent("steam.dll"))
            }
        } else if name != "Steam.dll" {
            // no legacycompat folder: the bridge itself stands in (games that check signatures will refuse it)
            let arch = name == "steamclient.dll" ? "i386-windows" : "x86_64-windows"
            stageFile(bridge.appendingPathComponent("\(arch)/lsteamclient.dll"), steamDir.appendingPathComponent(name))
        }
    }
    // Steam's library list as a Windows Steam folder has it: some games (Source engine titles) only start when they
    // are installed inside a library Steam knows. The Mac libraries are listed with their Z: paths.
    writeLibraryFolders(steamDir: steamDir, client: client.root)
    try? fm.createDirectory(at: steamDir.appendingPathComponent("config"), withIntermediateDirectories: true)
    // the bridge's own placeholders, so Wine's loader finds lsteamclient.dll in the system folders
    let windows = prefix.appendingPathComponent("drive_c/windows")
    stageFile(bridge.appendingPathComponent("x86_64-windows/lsteamclient.dll"), windows.appendingPathComponent("system32/lsteamclient.dll"))
    stageFile(bridge.appendingPathComponent("i386-windows/lsteamclient.dll"), windows.appendingPathComponent("syswow64/lsteamclient.dll"))
    // steam.exe on disk is Valve's signed SteamService.exe when available (games check that file too); Wine runs
    // Tessera's built-in steam.exe in its place (WINEDLLOVERRIDES steam.exe=b), so the running process has the
    // path and file games expect and does what Tessera needs.
    let service = legacy.appendingPathComponent("SteamService.exe")
    stageFile(fm.fileExists(atPath: service.path) ? service : bridge.appendingPathComponent("x86_64-windows/steam.exe"),
              steamDir.appendingPathComponent("steam.exe"))
    return steamDir.appendingPathComponent("steam.exe")
}

let steamExe = stageSteam(prefix)
stageBackend(prefix, backendDir: env["TESSERA_BACKEND_DIR"])
// Steam starts tools in the working folder the program expects (a game's install folder, or Steam's own folder for
// install scripts, which name their files relative to it); only without one is the program's folder used.
let steamCwd = FileManager.default.currentDirectoryPath
let gameDir = steamCwd != "/" && FileManager.default.fileExists(atPath: steamCwd)
    ? URL(fileURLWithPath: steamCwd) : URL(fileURLWithPath: exePath).deletingLastPathComponent()
// Steam's first-start scripts run Microsoft's installers. Older scripts give them no switches, so the Visual C++
// installer opens its licence window and DirectX's DXSETUP its setup wizard, and both wait for clicks. Before Steam's
// script runner reads the script, the quiet switch is added where the script has none (/q for Visual C++: tested with
// the 2005 SP1 package, accepted by the later ones too; /silent for DXSETUP: needs patch rule 4s).
func quietInstallScript(_ script: URL) {
    guard var text = try? String(contentsOf: script, encoding: .utf8) else { return }
    // Visual C++ 2005-2013 ("vcredist_x86/x64.exe"), Visual C++ 2015-2022 ("VC_redist.x86/x64.exe"), DirectX setup,
    // OpenAL and the legacy PhysX system software, each with its own quiet switch.
    let quiet: [(matches: (String) -> Bool, args: String)] = [
        ({ $0.hasSuffix("vcredist_x86.exe") || $0.hasSuffix("vcredist_x64.exe") }, "/q"),
        ({ $0.hasSuffix("vc_redist.x86.exe") || $0.hasSuffix("vc_redist.x64.exe") }, "/install /quiet /norestart"),
        ({ $0.hasSuffix("dxsetup.exe") }, "/silent"),
        ({ $0.hasSuffix("oalinst.exe") }, "/s"),
        ({ $0.contains("physx") && $0.hasSuffix(".exe") }, "/quiet"),
    ]
    var lines = text.components(separatedBy: "\n")
    var i = 0, added = 0
    while i < lines.count {
        let line = lines[i]
        // "process N"   "path"
        if let r = line.range(of: #"^(\s*)"process (\d+)"\s+"([^"]*)""#, options: .regularExpression) {
            let match = String(line[r])
            let indent = String(match.prefix { $0 == "\t" || $0 == " " })
            let number = match.components(separatedBy: "\"")[1].replacingOccurrences(of: "process ", with: "")
            let path = match.components(separatedBy: "\"")[3].lowercased()
            // does the same block already name arguments for this process?
            var j = i + 1, hasCommand = false
            while j < lines.count, !lines[j].contains("}") {
                if lines[j].contains("\"command \(number)\"") { hasCommand = true; break }
                j += 1
            }
            if !hasCommand, let q = quiet.first(where: { $0.matches(path) }) {
                lines.insert("\(indent)\"command \(number)\"\t\t\"\(q.args)\"", at: i + 1)
                added += 1
                i += 1
            }
        }
        i += 1
    }
    guard added > 0 else { return }
    text = lines.joined(separator: "\n")
    if (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil {
        log("install script: silent switches added for \(added) installer(s)")
    }
}
if URL(fileURLWithPath: exePath).lastPathComponent.lowercased() == "iscriptevaluator.exe",
   let arg = gameArgs.first(where: { $0.lowercased().hasSuffix(".vdf") }) {
    quietInstallScript(gameDir.appendingPathComponent(arg.replacingOccurrences(of: "\\", with: "/")))
}
log("runtime \(runtime.root.path)")
let tesseraVars = env.keys.filter { $0.hasPrefix("TESSERA_") }.sorted().map { "\($0)=\(env[$0]!)" }
if !tesseraVars.isEmpty { log("settings \(tesseraVars.joined(separator: " "))") }
log("prefix  \(prefix.path)")
log("folder  \(gameDir.path)")
var launchEnv = env
launchEnv["TESSERA_WORKDIR"] = windowsPath(forUnix: gameDir.path)   // steam.exe starts the game there
// Chromium-based games (NW.js, e.g. RPG Maker; CEF) draw through ANGLE's Direct3D 11. In 32-bit games that is
// WineD3D, whose Vulkan path shows nothing for them (window stays empty); its OpenGL path draws. 64-bit games use
// D3DMetal and do not read this. A game's own WINE_D3D_CONFIG wins.
let exeDir = URL(fileURLWithPath: exePath).deletingLastPathComponent()
if launchEnv["WINE_D3D_CONFIG"] == nil,
   ["nw.dll", "libcef.dll"].contains(where: { name in
       [exeDir, gameDir].contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path) } }) {
    launchEnv["WINE_D3D_CONFIG"] = "renderer=gl"
    log("Chromium-based game: WineD3D draws through OpenGL")
}
// Extra arguments from the game's Tessera settings (TESSERA_GAME_ARGS, separated by spaces) go after Steam's.
var launchArgs = gameArgs + (env["TESSERA_GAME_ARGS"] ?? "").split(separator: " ").map(String.init)
let rendererArgs = beamNGRendererArgs(exe: exePath, env: env)
if !rendererArgs.isEmpty {
    launchArgs += rendererArgs
    log("BeamNG engine: Direct3D 11 renderer (\(rendererArgs.joined(separator: " ")))")
}
log("start   \(exePath) \(launchArgs.joined(separator: " "))")
let status = runProcess(runtime.loader, ["start.exe", "/wait", "/unix", steamExe.path, windowsPath(forUnix: exePath)] + launchArgs,
                        env: launchEnv, cwd: gameDir)
log("game exited with \(status)")
if verb == "waitforexitandrun" {
    // the game may have started other processes (launchers, crash handlers); Steam counts them as the game
    runProcess(runtime.server, ["-w"], env: env)
    log("all processes of the prefix have exited")
}
exit(status)
