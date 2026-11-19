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

func wineEnvironment(prefix: URL) -> [String: String] {
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
    env["WINEDEBUG"] = env["WINEDEBUG"] ?? "-all"
    // no Mono/Gecko installer prompts; games that need .NET bring their own runtime
    // winemenubuilder off: it would put shortcut apps into ~/Applications when games install
    let overrides = ["mscoree,mshtml=d", "winemenubuilder.exe=d", "steam.exe=b", env["WINEDLLOVERRIDES"]].compactMap { $0 }.filter { !$0.isEmpty }
    env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
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
    // The app's graphics choice, translated to the runtime's backend folder (D3DMetal is the runtime's default).
    let graphics = env["TESSERA_GRAPHICS"] ?? "d3dmetal"
    switch graphics {
    case "dxmt": env["TESSERA_BACKEND_DIR"] = "\(root)/lib/dxmt"
    case "wined3d": env["TESSERA_BACKEND_DIR"] = "\(root)/lib/wined3d"
    default: env.removeValue(forKey: "TESSERA_BACKEND_DIR")
    }
    env["TESSERA_ACTIVE_GRAPHICS_BACKEND"] = graphics
    if graphics == "d3dmetal" {
        // Apple's D3DMetal helper is loaded into every process: it registers the native code D3DMetal runs
        // inside the Intel (Rosetta) process, so Wine's exception handling knows about it
        env["TESSERA_APPLEGPTK_LIBD3DSHARED_PATH"] = "\(root)/lib64/apple_gptk/external/libd3dshared.dylib"
    }
    // Steam's own overlay libraries are for native games; Tessera adds them back when the overlay is supported.
    env.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
    return env
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

func killPrefix(_ env: [String: String]) {
    runProcess(runtime.server, ["-k"], env: env)
}

// MARK: - prefix

func ensurePrefix(_ prefix: URL, env: [String: String]) {
    let marker = prefix.appendingPathComponent("system.reg")
    if FileManager.default.fileExists(atPath: marker.path) { return }
    log("creating prefix \(prefix.path)")
    try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    let started = Date()
    runProcess(runtime.loader, ["wineboot", "--init"], env: env)
    // wineserver writes the registry when it exits, so wait for it before anything reads the prefix
    runProcess(runtime.server, ["-w"], env: env)
    FileManager.default.createFile(atPath: prefix.appendingPathComponent(".tessera").path, contents: Data("made by Tessera\n".utf8))
    log("prefix ready after \(Int(Date().timeIntervalSince(started))) s")
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
let prefix = prefixURL()
let env = wineEnvironment(prefix: prefix)
ensurePrefix(prefix, env: env)

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
log("runtime \(runtime.root.path)")
let tesseraVars = env.keys.filter { $0.hasPrefix("TESSERA_") }.sorted().map { "\($0)=\(env[$0]!)" }
if !tesseraVars.isEmpty { log("settings \(tesseraVars.joined(separator: " "))") }
log("prefix  \(prefix.path)")
log("folder  \(gameDir.path)")
var launchEnv = env
launchEnv["TESSERA_WORKDIR"] = windowsPath(forUnix: gameDir.path)   // steam.exe starts the game there
log("start   \(exePath) \(gameArgs.joined(separator: " "))")
let status = runProcess(runtime.loader, ["start.exe", "/wait", "/unix", steamExe.path, windowsPath(forUnix: exePath)] + gameArgs,
                        env: launchEnv, cwd: gameDir)
log("game exited with \(status)")
if verb == "waitforexitandrun" {
    // the game may have started other processes (launchers, crash handlers); Steam counts them as the game
    runProcess(runtime.server, ["-w"], env: env)
    log("all processes of the prefix have exited")
}
exit(status)
