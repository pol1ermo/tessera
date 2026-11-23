// tessera-run - the program Steam runs for every Windows game assigned to the Tessera compatibility tool.
//
// Steam calls it as `run <verb> <command...>` (toolmanifest.vdf: "commandline" "/run %verb%"):
//   waitforexitandrun <exe> [args]   start the game, return only when every process of the game has exited
//   run <exe> [args]                 start a helper (install scripts and the like) and wait for it
//   getcompatpath <unix path>        print the Windows path Steam should use for a file
//   getnativepath <windows path>     print the Unix path for a Windows path
// Tessera's library inside Steam and Tessera's window also call it for the games guard (GamesGuard.swift).
// Steam passes the game's context in the environment (STEAM_COMPAT_DATA_PATH, SteamAppId, Steam3Master, ...).
import AppKit
import Darwin
import Foundation

// Not about one game: keeping Steam away from installed Windows games while Tessera is not active in it
// (GamesGuard.swift): `run steam-guard <steam pid>`, `run park-games`, `run unpark-games`, `run parked-games`.
if CommandLine.arguments.count > 1, GamesGuard.verbs.contains(CommandLine.arguments[1]) {
    exit(GamesGuard.main(Array(CommandLine.arguments.dropFirst())))
}

// MARK: - logging

let appID = ProcessInfo.processInfo.environment["SteamAppId"] ?? ProcessInfo.processInfo.environment["STEAM_COMPAT_APP_ID"] ?? "0"
// Steam's content log and where it ends now: a "Terminating" line for this game after this point is Steam's Stop button
// (watchForSteamStop below).
let steamContentLog = NSHomeDirectory() + "/Library/Application Support/Steam/logs/content_log.txt"
let steamContentLogStart = ((try? FileManager.default.attributesOfItem(atPath: steamContentLog))?[.size] as? NSNumber)?.uint64Value ?? 0
let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tessera")
try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
let logURL = logDir.appendingPathComponent("game-\(appID).log")
// Opened in append mode: the game's programs inherit this file as their output, and in append mode every write goes
// to the file's current end, so the log can be cut short while they hold it open (cutLog below).
let logFD = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
let logHandle: FileHandle? = logFD >= 0 ? FileHandle(fileDescriptor: logFD, closeOnDealloc: false) : nil

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
    let line = "[\(stamp)] \(message)\n"
    logHandle?.write(line.data(using: .utf8)!)
}

// A game's log keeps every session and had no limit. Two limits keep it from filling the disk:
// - when a session starts, a log over 32 MB is cut down to its last 4 MB;
// - during a session the size is looked at every 20 s, and a log over 256 MB is cut down the same way. Only a
//   program that writes the same line without end gets there (The Forest on 1.3.1: a Wine warning more than 100,000 times a
//   second, a 7.4 GB log after 22 minutes of play); it is then cut about once a minute instead of growing.
let logStartLimit: UInt64 = 32 << 20
let logSessionLimit: UInt64 = 256 << 20
let logKeep = 4 << 20

func cutLog(over limit: UInt64) {
    var info = stat()
    guard logFD >= 0, fstat(logFD, &info) == 0, UInt64(info.st_size) > limit else { return }
    let size = UInt64(info.st_size)
    var tail = Data()
    if let reader = FileHandle(forReadingAtPath: logURL.path) {
        if (try? reader.seek(toOffset: size - UInt64(logKeep))) != nil { tail = reader.readData(ofLength: logKeep) }
        try? reader.close()
        // from the first whole line
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail.subdata(in: tail.index(after: newline)..<tail.endIndex) }
    }
    ftruncate(logFD, 0)
    log("this log had grown to \(size >> 20) MB; everything before its last \(logKeep >> 20) MB was removed")
    logHandle?.write(tail)
}
cutLog(over: logStartLimit)

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

/// The version and build time of the Tessera.app this runtime sits in, e.g. "1.2.11.1 (build 202611211755)": two builds
/// of one version can then be told apart in a log someone sends.
func tesseraVersion() -> String {
    let plist = runtime.root.appendingPathComponent("../../Info.plist").standardized
    guard let info = NSDictionary(contentsOf: plist) else { return "unknown (a runtime outside Tessera.app)" }
    return "\(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))"
}

/// The Mac a log comes from, e.g. "macOS 27.2 (Build 27C5318a), Mac15,9, Apple M3 Max, 64 GB memory".
func systemSummary() -> String {
    func value(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }
    let system = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: "")
    let memory = (ProcessInfo.processInfo.physicalMemory + (1 << 29)) >> 30
    return "macOS \(system), \(value("hw.model")), \(value("machdep.cpu.brand_string")), \(memory) GB memory"
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
    let own = compat.appendingPathComponent("tessera")
    let fm = FileManager.default
    if !fm.fileExists(atPath: pfx.path) || fm.fileExists(atPath: pfx.appendingPathComponent(".tessera").path) {
        return pfx
    }
    // a folder of Tessera's own that is already in use stays in use
    if fm.fileExists(atPath: own.appendingPathComponent("system.reg").path) { return own }
    // Before the first start of a game that has cloud saves, Steam itself makes pfx/drive_c/users/steamuser and puts
    // the saves there. That is no other tool's Windows folder (it has no registry), and it is the one to set up: up
    // to 1.2.11 Tessera took it for one and made its own folder beside it, where the game never saw those saves.
    if !fm.fileExists(atPath: pfx.appendingPathComponent("system.reg").path) { return pfx }
    return own
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
    // .NET Framework programs (launchers, tools) run on Wine Mono and pages in embedded browsers on Wine Gecko (the
    // Internet Explorer engine); the runtime carries both (share/wine/mono, share/wine/gecko), so Wine never asks to
    // download them
    // winemenubuilder off: it would put shortcut apps into ~/Applications when games install
    // Microsoft's C++ runtime: Steam installs it into the Windows folder on a game's first start (its redistributable
    // step), as on Windows, and newer games accept only that version (Unreal 5's starter refused Wine's 14.42 copy:
    // "Microsoft Visual C++ 2015-2022 Redistributable (x64) is required"). The installed files go first; without them
    // Wine's own copies load.
    // A game's own WINEDLLOVERRIDES (settings above) comes last, so it adds to these instead of replacing them.
    // Microsoft's Visual C++ 2005-2013 runtimes and MFC come with Tessera's Windows extras (WindowsExtras.swift):
    // theirs first as well, Wine's own where a folder does not have them (yet).
    let msvcRuntime = "msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,msvcp140_codecvt_ids,vcruntime140,vcruntime140_1,concrt140,"
        + "vcomp140,vcamp140,vccorlib140,msvcp120,msvcr120,vcomp120,msvcp110,msvcr110,vcomp110,atl110,msvcp100,msvcr100,vcomp100,atl100,"
        + "msvcp90,msvcr90,msvcm90,vcomp90,atl90,msvcp80,msvcr80,msvcm80,vcomp,atl80=n,b"
    // winedbg off: a crashed game closes (Wine's crash debugger kept crashed programs open for good - Steam still showed
    // them running); the log keeps Wine's "Unhandled page fault ..." line with the crash address.
    let overrides = ["winemenubuilder.exe=d", "winedbg.exe=d", "steam.exe=b", msvcRuntime,
                     env["WINEDLLOVERRIDES"]].compactMap { $0 }.filter { !$0.isEmpty }
    env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
    // The app's graphics choice, translated to the runtime's backend folder (D3DMetal is the runtime's default).
    // Automatic (no choice in the game's settings): D3DMetal, except for engines D3DMetal is known to trip up.
    var graphics = env["TESSERA_GRAPHICS"] ?? "d3dmetal"
    // "d3dmetal3" is D3DMetal with Apple's 3.0 instead of 4.0 (see below)
    var d3dMetal3 = graphics == "d3dmetal3"
    if d3dMetal3 { graphics = "d3dmetal" }
    let macOS = macOSVersion(env)
    if env["TESSERA_GRAPHICS"] == nil, let game = gameNeedingDXVK(exe: exe, env: env) {
        graphics = "dxvk"
        log("\(game): graphics through DXVK (automatic choice)")
    } else if env["TESSERA_GRAPHICS"] == nil, let engine = engineNeedingDXMT(exe: exe, env: env) {
        // DXMT's Metal bridge is made for macOS 15 and later
        graphics = macOS >= (15, 0) ? "dxmt" : "dxvk"
        log("\(engine) game: graphics through \(graphics == "dxmt" ? "DXMT" : "DXVK (DXMT needs macOS 15)") (automatic choice)")
    }
    // Apple's D3DMetal comes twice in the runtime. Apple marks D3DMetal 4's shader library for macOS 26.4 and later
    // and D3DMetal 3.0's for macOS 15.4 and later, so a macOS before 26.4 gets 3.0, and a game's settings can ask for
    // 3.0 as well (4.0 is a beta). Before macOS 15.4 neither loads: DirectX 9-11 then go through DXVK by themselves.
    if graphics == "d3dmetal" {
        let has3 = FileManager.default.fileExists(atPath: "\(root)/lib/d3dmetal3/x86_64-windows/d3d12.dll")
        if !(macOS >= (15, 4)) {
            if env["TESSERA_GRAPHICS"] == nil {
                graphics = "dxvk"
                d3dMetal3 = false
                log("macOS \(macOS.0).\(macOS.1): Apple's D3DMetal needs macOS 15.4 or later; DirectX 9-11 through DXVK (DirectX 12 games need a newer macOS)")
            } else {
                log("macOS \(macOS.0).\(macOS.1): Apple's D3DMetal needs macOS 15.4 or later and may not start here")
            }
        } else if !has3 {
            d3dMetal3 = false
        } else if !d3dMetal3, !(macOS >= (26, 4)) {
            d3dMetal3 = true
            log("macOS \(macOS.0).\(macOS.1): D3DMetal 3.0 (D3DMetal 4 needs macOS 26.4 or later)")
        }
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
    default:
        // D3DMetal 4 is the runtime's default folder; 3.0's Direct3D DLLs are a backend folder like the others
        if graphics == "d3dmetal", d3dMetal3 { env["TESSERA_BACKEND_DIR"] = "\(root)/lib/d3dmetal3" }
        else { env.removeValue(forKey: "TESSERA_BACKEND_DIR") }
    }
    env["TESSERA_ACTIVE_GRAPHICS_BACKEND"] = graphics
    env.removeValue(forKey: "TESSERA_D3DMETAL")
    if graphics == "d3dmetal" {
        // Apple's D3DMetal helper is loaded into every process: it registers the native code D3DMetal runs
        // inside the Intel (Rosetta) process, so Wine's exception handling knows about it. It is the helper of the
        // D3DMetal version in use (one process never holds both).
        env["TESSERA_APPLEGPTK_LIBD3DSHARED_PATH"] = "\(root)/lib64/\(d3dMetal3 ? "apple_gptk3" : "apple_gptk")/external/libd3dshared.dylib"
        env["TESSERA_D3DMETAL"] = d3dMetal3 ? "3" : "4"
        // D3DMetal 4 draws DirectX 12 through its new Metal 4 backend on macOS 27 and through its Metal 3 backend on
        // macOS 26. Measured in The Last of Us Part I (21 Nov 2026, M3 Max, 95 fps): with the Metal 3 backend a frame
        // is on screen 6 ms after the game hands it over instead of 8 ms, and a mouse turn shows after 41 ms instead
        // of 48 ms, at the same frame rate. So Metal 3 is Tessera's choice on every macOS; a game's "Metal 4 graphics
        // path" setting (D3DM_MTL4=1) gives Apple's default back.
        if !d3dMetal3 { env["D3DM_MTL4"] = env["D3DM_MTL4"] ?? "0" }
    }
    // DLSS through MetalFX (the game's "DLSS through MetalFX" setting, D3DM_ENABLE_METALFX=1, with D3DMetal): D3DMetal 4
    // answers a game's NVIDIA DLSS calls with Apple's MetalFX upscaler. The game has to see an NVIDIA card
    // (D3DM_VENDOR_ID) and NVIDIA's NVAPI and NGX libraries: Apple's stand-ins come from the runtime's metalfx folder,
    // for this game's programs only (stageDLSS puts the signed files NGX checks into its system32). Chromium-based
    // launchers stall on nvapi64 and Steam's helpers have no use for it, so in such a game they get the stand-ins off.
    if dlssThroughMetalFX(env) {
        if isChromiumBased(exe: exe) || isSteamHelper(exe) {
            env["WINEDLLOVERRIDES"] = "nvapi64,nvngx,_nvngx=d;" + (env["WINEDLLOVERRIDES"] ?? "")
        } else {
            env["WINEDLLPATH"] = (env["WINEDLLPATH"] ?? "") + ":\(root)/lib/metalfx"
            env["D3DM_VENDOR_ID"] = env["D3DM_VENDOR_ID"] ?? "0x10de"
            env["WINEDLLOVERRIDES"] = "nvapi64,nvngx,_nvngx=b;" + (env["WINEDLLOVERRIDES"] ?? "")
            log("DLSS through MetalFX: on (the game sees an NVIDIA card; Apple's MetalFX does the upscaling)")
        }
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

/// This Mac's macOS version (major, minor). TESSERA_TEST_MACOS=15.7 in a game's settings pretends another one, to test
/// what Tessera chooses on an older macOS.
func macOSVersion(_ env: [String: String]) -> (Int, Int) {
    if let test = env["TESSERA_TEST_MACOS"] {
        let parts = test.split(separator: ".").compactMap { Int($0) }
        if let major = parts.first { return (major, parts.count > 1 ? parts[1] : 0) }
    }
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return (v.majorVersion, v.minorVersion)
}

/// The Elder Scrolls V: Skyrim Special Edition crashes in its own code under both Metal translations of Direct3D 11
/// (D3DMetal and DXMT: an access violation about 12 s in, at the intro video and again at New Game; others report
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
/// Konami's engine of its Metal Gear collections (EngineSupport/stovk.bin next to the program and its launcher): every
/// frame D3DMetal shows is black, DXMT draws it (METAL GEAR & METAL GEAR 2: Solid Snake).
func engineNeedingDXMT(exe: String, env: [String: String]) -> String? {
    let dir = URL(fileURLWithPath: exe).deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("data.win").path) { return "GameMaker" }
    if FileManager.default.fileExists(atPath: dir.appendingPathComponent("EngineSupport/stovk.bin").path) {
        return "Konami Metal Gear collection"
    }
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
    // the Windows extras installed into it (WindowsExtras.swift) are part of it too
    let key = stableHash("\(runtime.root.path)|\(Int(changed))|\(attrs[.size] ?? 0)|\(mono)|extras \(windowsExtrasVersion)")
    let template = templatesDir.appendingPathComponent(key)
    // Ready when Wine's set-up finished (it writes .update-timestamp at its end). The registry alone does not say so:
    // the Wine server writes one even when every program stopped at start (Tessera up to 1.2.10 on macOS before 27),
    // and such a half-made template was cloned into every game's folder.
    let ready = { fm.fileExists(atPath: template.appendingPathComponent("system.reg").path)
        && fm.fileExists(atPath: template.appendingPathComponent(".update-timestamp").path) }
    if ready() { return template }
    if fm.fileExists(atPath: template.path) {
        log("the Windows folder template is incomplete (made by an earlier Tessera that could not start Windows programs here); making it again")
        try? fm.removeItem(at: template)
    }
    log("building the Windows folder template (once per Tessera version)")
    // built under a temporary name, so two games starting at once never clone a half-built one
    let building = templatesDir.appendingPathComponent("\(key).building-\(getpid())")
    try? fm.removeItem(at: building)
    buildPrefix(building, env: env)
    installWindowsExtras(building, env: env, waitForServer: true)
    if fm.fileExists(atPath: building.appendingPathComponent("system.reg").path),
       fm.fileExists(atPath: building.appendingPathComponent(".update-timestamp").path), !ready() {
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
// the log's size limit during the session (cutLog above)
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 20)
        cutLog(over: logSessionLimit)
    }
}
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
// a folder made before this Tessera version (or while offline) gets the Windows extras now, once
installWindowsExtras(prefix, env: env, waitForServer: false)
// Microsoft's .NET Framework, only for the few launchers Wine Mono cannot run (DotNetFramework.swift); asks first
if let reason = dotNetFrameworkReason(exe: exePath, env: env) { ensureDotNetFramework(prefix, env: env, reason: reason) }
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

// Steam's Stop button. On the Mac, Stop ("Exit game? Unsaved game data may be lost", Confirm) sends the game nothing,
// neither a signal nor a request to quit: Steam marks the game "Terminating", closes the game's connection to Steam
// and then waits, showing "Stopping", until the game's processes are gone. A game that notices the lost connection
// quits by itself (R.E.P.O.); most do not, and the player had to end them in Activity Monitor (GitHub issue 1).
// Steam for Windows ends the game's process outright, so this launcher does it: Steam writes the state change to its
// content log ("AppID 1755910 state changed : Fully Installed,App Running,Terminating,"); when that line appears for
// this game, the game gets 3 seconds to close by itself and then every program of its Windows folder is ended.
func watchForSteamStop() {
    guard appID != "0" else { return }
    let needle = "AppID \(appID) state changed : "
    Thread.detachNewThread {
        var offset = steamContentLogStart
        while true {
            Thread.sleep(forTimeInterval: 0.5)
            guard let handle = FileHandle(forReadingAtPath: steamContentLog) else { continue }
            let size = (try? handle.seekToEnd()) ?? 0
            if size < offset { offset = 0 }                        // Steam started a new log file
            guard size > offset, (try? handle.seek(toOffset: offset)) != nil else { try? handle.close(); continue }
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            // whole lines only; an unfinished last line is read again the next time
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let whole = data[data.startIndex...lastNewline]
            offset += UInt64(whole.count)
            let stopped = String(decoding: whole, as: UTF8.self).split(separator: "\n")
                .contains { $0.contains(needle) && $0.contains("Terminating") }
            if stopped {
                log("Steam's Stop button: the game gets 3 s to close by itself")
                Thread.sleep(forTimeInterval: 3)
                log("Steam's Stop button: ending every program of the game's Windows folder")
                killPrefix(env)
                exit(0)
            }
        }
    }
}
watchForSteamStop()

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

/// The game's "DLSS through MetalFX" setting is on, it draws through D3DMetal 4, and the runtime has Apple's stand-ins.
func dlssThroughMetalFX(_ env: [String: String]) -> Bool {
    env["D3DM_ENABLE_METALFX"] == "1" && env["TESSERA_ACTIVE_GRAPHICS_BACKEND"] == "d3dmetal" && env["TESSERA_D3DMETAL"] != "3"
        && FileManager.default.fileExists(atPath: runtime.root.appendingPathComponent(dlssFolder).appendingPathComponent("nvngx-on-metalfx.dll").path)
}
var dlssFolder: String { "lib/metalfx/x86_64-windows" }   // computed: main.swift's stored globals start in file order

/// DLSS through MetalFX in the game's Windows folder: NVIDIA's NGX (inside a game's DLSS plugin) loads NVIDIA's core
/// from the folder the registry names (NGXCore FullPath), and only with a valid signature. So Apple's signed stand-ins go
/// into system32 as real files (Wine's 1 KB placeholders fail that check: CERT_E_UNTRUSTEDROOT). With the setting off,
/// Tessera's copies and the registry entry come out again: the folder looks like one without an NVIDIA card.
func stageDLSS(_ prefix: URL, env: [String: String]) {
    let fm = FileManager.default
    let apple = runtime.root.appendingPathComponent(dlssFolder)
    let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
    let files = [("nvapi64.dll", "nvapi64.dll"), ("nvngx-on-metalfx.dll", "nvngx.dll"), ("nvngx-on-metalfx.dll", "_nvngx.dll")]
    let key = #"HKLM\SOFTWARE\NVIDIA Corporation\Global\NGXCore"#
    func size(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int }
    func hasKey() -> Bool {
        let registry = (try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)) ?? ""
        return registry.contains(#"[Software\\NVIDIA Corporation\\Global\\NGXCore]"#)
    }
    var e = env
    e["WINEDEBUG"] = "-all"
    e["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;winedbg.exe=d"
    if dlssThroughMetalFX(env) {
        for (from, to) in files { stageFile(apple.appendingPathComponent(from), system32.appendingPathComponent(to)) }
        if !hasKey() {
            runProcess(runtime.loader, ["reg", "add", key, "/v", "FullPath", "/t", "REG_SZ", "/d", #"C:\Windows\System32"#, "/f"], env: e)
            log("DLSS through MetalFX: Apple's NVIDIA stand-ins put into this game's Windows folder")
        }
        return
    }
    // setting off: only Tessera's own copies (Apple's files, by size) go; a game's or driver's own files stay
    let ours = files.filter { from, to in
        let s = size(system32.appendingPathComponent(to))
        return s != nil && s == size(apple.appendingPathComponent(from))
    }
    guard !ours.isEmpty else { return }
    for (_, to) in ours { try? fm.removeItem(at: system32.appendingPathComponent(to)) }
    if hasKey() { runProcess(runtime.loader, ["reg", "delete", key, "/f"], env: e) }
    log("DLSS through MetalFX: off, Apple's NVIDIA stand-ins taken out of this game's Windows folder")
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

/// Valve's Windows Steam files (ValveFiles.swift): Tessera's own download, else a set another tool put into Steam's
/// legacycompat folder; nil when this Mac has neither. TESSERA_TEST_NO_VALVE_FILES=1 pretends there are none and
/// that they cannot be downloaded (testing the stand-ins).
func valveLegacyFolder() -> URL? {
    if env["TESSERA_TEST_NO_VALVE_FILES"] == "1" { return nil }
    if valveFilesAreDownloaded() { return valveFilesFolder }
    let steams = steamClientFolders().binaries.appendingPathComponent("legacycompat")
    return valveFilesAreIn(steams) ? steams : nil
}

/// The app downloads Valve's files as soon as it opens; this is for a game started before the app ever did.
func ensureValveFiles() {
    guard valveLegacyFolder() == nil, env["TESSERA_TEST_NO_VALVE_FILES"] != "1" else { return }
    log("Valve's Steam files for Windows games are not on this Mac yet (the Mac Steam client does not include them); downloading them from Valve now (29 MB, once)")
    let started = Date()
    if let failure = downloadValveFiles(maxTime: 300) {
        log("Valve's Steam files: \(failure). Tessera's stand-ins are used for now; the download is tried again at the next start")
    } else {
        log("Valve's Steam files downloaded in \(Int(Date().timeIntervalSince(started))) s")
    }
}

/// Steam names its script runner inside its own legacycompat folder, and the runner starts its helper as
/// "legacycompat\\SteamService.exe" from Steam's folder: the layout of the Linux client, which has Valve's files there.
/// So Steam's legacycompat folder on the Mac gets copies of the files Tessera downloaded (Steam makes that folder
/// itself, for the script it hands over; "Remove from Steam" takes the copies out again).
func mirrorValveFilesIntoSteam() {
    guard env["TESSERA_TEST_NO_VALVE_FILES"] != "1", valveFilesAreDownloaded() else { return }
    let target = steamClientFolders().binaries.appendingPathComponent("legacycompat")
    try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for file in valveFiles {
        stageFile(valveFilesFolder.appendingPathComponent(file.name), target.appendingPathComponent(file.name))
    }
}

func stageSteam(_ prefix: URL) -> URL {
    let fm = FileManager.default
    let bridge = runtime.root.appendingPathComponent("lib/tessera-steam")
    let steamDir = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    try? fm.createDirectory(at: steamDir, withIntermediateDirectories: true)
    // The Steam folder gets Valve's real Windows files: some games check that steamclient.dll carries Valve's
    // signature before loading it. The Mac Steam client does not include them, so Tessera downloads them from Valve
    // (ValveFiles.swift). Tessera's Wine loads the bridge (lsteamclient) whenever a game loads steamclient, so the
    // real ones never run.
    let client = steamClientFolders()
    let legacy = valveLegacyFolder() ?? client.binaries.appendingPathComponent("legacycompat")
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
            // Valve's files could not be downloaded: the bridge itself stands in (games that check signatures
            // refuse it)
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

/// Steam's cloud sync maps saves in a game's My Documents (and the older Application Data folders) to the Windows XP
/// folder names inside the game's Windows folder, as for Proton, whose prefixes link those names to today's folders.
/// Without the links Steam synced a "My Documents" folder the game never uses: saves in Documents were not uploaded,
/// and downloaded ones landed beside the game's (Skyrim, Borderlands 2). Like Proton, at every start (Steam may put
/// files there any time): merge what Steam put under the old name into the new folder - only folders the new one
/// does not have, two copies of a save folder are never merged - keep the old one as "... BACKUP", link the name.
func migrateUserPaths(_ prefix: URL) {
    let fm = FileManager.default
    let user = prefix.appendingPathComponent("drive_c/users/steamuser")
    func merge(_ src: URL, _ dst: URL, root: Bool) {
        if fm.fileExists(atPath: dst.path) && !root { return }
        try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for item in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: keys)) ?? [] {
            let target = dst.appendingPathComponent(item.lastPathComponent)
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true && v?.isSymbolicLink != true { merge(item, target, root: false) }
            else if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: item, to: target) }
        }
    }
    for (old, new, link) in [("Local Settings/Application Data", "AppData/Local", "../AppData/Local"),
                             ("Application Data", "AppData/Roaming", "./AppData/Roaming"),
                             ("My Documents", "Documents", "./Documents")] {
        let oldURL = user.appendingPathComponent(old), newURL = user.appendingPathComponent(new)
        guard fm.fileExists(atPath: newURL.path) else { continue }
        switch (try? fm.attributesOfItem(atPath: oldURL.path))?[.type] as? FileAttributeType {
        case .typeSymbolicLink?:
            if (try? fm.destinationOfSymbolicLink(atPath: oldURL.path)) == link { continue }
            try? fm.removeItem(at: oldURL)
        case .typeDirectory?:
            merge(oldURL, newURL, root: true)
            var backup = oldURL.path + " BACKUP", n = 2
            while fm.fileExists(atPath: backup) { backup = oldURL.path + " BACKUP \(n)"; n += 1 }
            guard (try? fm.moveItem(atPath: oldURL.path, toPath: backup)) != nil else { continue }
            log("Steam Cloud: \(old) now leads to \(new) (Steam's files merged, old folder kept as \"\(URL(fileURLWithPath: backup).lastPathComponent)\")")
        case nil:
            break
        default:
            continue                                   // a file of that name: leave it alone
        }
        try? fm.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: oldURL.path, withDestinationPath: link)
    }
}

ensureValveFiles()
mirrorValveFilesIntoSteam()
let steamExe = stageSteam(prefix)
stageBackend(prefix, backendDir: env["TESSERA_BACKEND_DIR"])
stageDLSS(prefix, env: env)
migrateUserPaths(prefix)
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
            } else if hasCommand, path.contains("vcredist"),
                      lines[j].range(of: #""/q:a""#, options: [.regularExpression, .caseInsensitive]) != nil,
                      let major = peFileVersionMajor(installerPath(path, gameDir: gameDir)), major >= 10 {
                // "/q:a" is the quiet switch of the IExpress packages of Visual C++ 2005 and 2008; the installer of
                // 2010 and later does not know it and opens its licence window (Borderlands 2's script)
                lines[j] = lines[j].replacingOccurrences(of: #""/q:a""#, with: "\"/q /norestart\"",
                                                         options: [.regularExpression, .caseInsensitive])
                log("install script: \(URL(fileURLWithPath: installerPath(path, gameDir: gameDir)).lastPathComponent) is Visual C++ \(major).x: /q:a -> /q /norestart")
                added += 1
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
/// The Mac path of an installer an install script names: %INSTALLDIR% is the game's folder (Steam passes it as
/// STEAM_COMPAT_INSTALL_PATH), Z: is the Mac's root and C: the game's Windows folder.
func installerPath(_ scriptPath: String, gameDir: URL) -> String {
    var p = scriptPath.replacingOccurrences(of: "\\\\", with: "/").replacingOccurrences(of: "\\", with: "/")
    let installDir = steamEnv["STEAM_COMPAT_INSTALL_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? gameDir.path
    if let r = p.range(of: "%installdir%", options: .caseInsensitive) {
        p.replaceSubrange(r, with: installDir)
    } else if p.lowercased().hasPrefix("z:/") {
        p = String(p.dropFirst(2))
    } else if p.lowercased().hasPrefix("c:/") {
        p = prefix.appendingPathComponent("drive_c").path + "/" + p.dropFirst(3)
    }
    return p
}

/// The major file version of a Windows program (its version resource's VS_FIXEDFILEINFO), or nil. Installers carry
/// their payload after their own resources, so the first such block is the program's own.
func peFileVersionMajor(_ path: String) -> Int? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
        let b = raw.bindMemory(to: UInt8.self)
        var i = 0
        while i + 12 <= b.count {
            if b[i] == 0xBD, b[i + 1] == 0x04, b[i + 2] == 0xEF, b[i + 3] == 0xFE {
                // dwSignature, dwStrucVersion, dwFileVersionMS = major << 16 | minor
                return Int(b[i + 10]) | Int(b[i + 11]) << 8
            }
            i += 1
        }
        return nil
    }
}

if URL(fileURLWithPath: exePath).lastPathComponent.lowercased() == "iscriptevaluator.exe",
   let arg = gameArgs.first(where: { $0.lowercased().hasSuffix(".vdf") }) {
    quietInstallScript(gameDir.appendingPathComponent(arg.replacingOccurrences(of: "\\", with: "/")))
}
log("runtime \(runtime.root.path)")
log("version \(tesseraVersion()) on \(systemSummary())")
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
// Steam runs a game's first-start scripts with Valve's iscriptevaluator.exe, which the Mac client does not have
// (mirrorValveFilesIntoSteam puts it there). Without it there is nothing to run: Steam is told so and asks again at
// the next start.
if URL(fileURLWithPath: exePath).lastPathComponent.lowercased() == "iscriptevaluator.exe",
   !FileManager.default.fileExists(atPath: exePath) {
    log("Steam's first-start step for this game is skipped: Valve's script runner is not on this Mac (its download failed, see above). Steam asks again at the next start")
    exit(1)
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
cutLog(over: logStartLimit)   // a session that wrote that much leaves its last 4 MB
exit(status)
