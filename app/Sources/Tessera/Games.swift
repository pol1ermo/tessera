import Foundation

/// An installed Steam game that Tessera runs.
struct Game: Identifiable, Hashable {
    let id: String              // Steam app id
    let name: String
    let installDir: URL
    let sizeOnDisk: Int64
    let lastPlayed: Date?

    var settingsFile: URL { Paths.settingsFile(appID: id) }
    var logFile: URL { Paths.gameLog(appID: id) }

    /// The game's Windows folder made by Tessera, or nil before the first start. Steam's layout is
    /// <library>/steamapps/compatdata/<id>/pfx; "tessera" next to it is used when another tool already owns pfx.
    var prefix: URL? {
        let compat = installDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("compatdata/\(id)")
        let fm = FileManager.default
        let pfx = compat.appendingPathComponent("pfx")
        if fm.fileExists(atPath: pfx.appendingPathComponent(".tessera").path) { return pfx }
        let own = compat.appendingPathComponent("tessera")
        return fm.fileExists(atPath: own.appendingPathComponent("system.reg").path) ? own : nil
    }
}

enum GameLibrary {
    /// Steam's library folders (libraryfolders.vdf), each holding a steamapps folder.
    static func libraries() -> [URL] {
        var out = [Paths.steamData]
        let vdf = Paths.steamApps.appendingPathComponent("libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            let re = try! NSRegularExpression(pattern: "\"path\"\\s*\"([^\"]+)\"")
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let url = URL(fileURLWithPath: ns.substring(with: m.range(at: 1)))
                if !out.contains(url) { out.append(url) }
            }
        }
        return out
    }

    /// Games set to Tessera one by one (Play the Windows Version): Steam then installs the Windows version, and may
    /// leave the Mac version's files next to it.
    static func gamesSetToTessera() -> Set<String> {
        let tools = Set([SteamSetup.toolName] + SteamSetup.legacyToolNames)
        return Set(CompatMappings.read().filter { $0.key != "0" && tools.contains($0.value.name) }.keys)
    }

    /// Installed games whose folder holds Windows programs and no Mac program, or that are set to Tessera on their
    /// own - the ones Tessera runs.
    static func windowsGames() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default
        let setToTessera = gamesSetToTessera()
        for lib in libraries() {
            let apps = lib.appendingPathComponent("steamapps")
            guard let files = try? fm.contentsOfDirectory(atPath: apps.path) else { continue }
            for f in files where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
                guard let kv = keyValues(apps.appendingPathComponent(f)),
                      let id = kv["appid"], let name = kv["name"], let dir = kv["installdir"] else { continue }
                if id == "228980" { continue }      // Steamworks Common Redistributables
                let install = apps.appendingPathComponent("common/\(dir)")
                guard isWindowsGame(install, macFilesAllowed: setToTessera.contains(id)) else { continue }
                let played = Double(kv["LastPlayed"] ?? "").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                games.append(Game(id: id, name: name, installDir: install,
                                  sizeOnDisk: Int64(kv["SizeOnDisk"] ?? "") ?? 0, lastPlayed: played))
            }
        }
        return games.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    /// Installed games that Steam gave their Mac version where that version cannot run: a 32-bit program (macOS 10.15
    /// and later run only 64-bit ones). Tessera can play their Windows version instead.
    static func macVersionsThatCannotRun() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default
        let setToTessera = gamesSetToTessera()
        for lib in libraries() {
            let apps = lib.appendingPathComponent("steamapps")
            guard let files = try? fm.contentsOfDirectory(atPath: apps.path) else { continue }
            for f in files where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
                guard let kv = keyValues(apps.appendingPathComponent(f)),
                      let id = kv["appid"], let name = kv["name"], let dir = kv["installdir"],
                      !setToTessera.contains(id) else { continue }
                let install = apps.appendingPathComponent("common/\(dir)")
                // a Mac version can carry Windows files from depots both versions share (Portal 2: portal2.exe), so
                // the Mac programs decide
                let programs = macPrograms(in: install)
                guard !programs.isEmpty, !programs.contains(where: macProgramRuns) else { continue }
                let played = Double(kv["LastPlayed"] ?? "").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                games.append(Game(id: id, name: name, installDir: install,
                                  sizeOnDisk: Int64(kv["SizeOnDisk"] ?? "") ?? 0, lastPlayed: played))
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Mac programs at the top of a game's folder: app bundles' programs and plain Mach-O programs (Valve's Source
    /// games: portal2_osx, hl2_osx). Steam installs them only when it installed the game's Mac version.
    static func macPrograms(in dir: URL) -> [URL] {
        guard let top = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var programs: [URL] = []
        for name in top.prefix(400) {
            let url = dir.appendingPathComponent(name)
            if name.hasSuffix(".app") {
                if let program = appProgram(url) { programs.append(program) }
            } else if !name.contains("."), isMachO(url) {
                programs.append(url)
            }
        }
        return programs
    }

    /// Whether a file is a Mach-O program or a universal file of them.
    static func isMachO(_ file: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
              let h = FileHandle(forReadingAtPath: file.path) else { return false }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 8)) ?? Data())
        guard b.count == 8 else { return false }
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let count = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        switch magic {
        case 0xCEFA_EDFE, 0xCFFA_EDFE, 0xFEED_FACE, 0xFEED_FACF: return true
        case 0xCAFE_BABE, 0xCAFE_BABF: return count > 0 && count < 32          // (a Java class file has a large count)
        default: return false
        }
    }

    /// An app bundle's program (Info.plist CFBundleExecutable).
    static func appProgram(_ app: URL) -> URL? {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let exe = plist["CFBundleExecutable"] as? String else { return nil }
        return app.appendingPathComponent("Contents/MacOS/\(exe)")
    }

    /// Whether a Mac program can run here: a 64-bit Intel or Apple-silicon program, alone or in a universal file.
    /// Files that are not Mach-O programs (scripts) count as runnable.
    static func macProgramRuns(_ program: URL) -> Bool {
        guard let h = FileHandle(forReadingAtPath: program.path) else { return true }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 4096)) ?? Data())
        func be32(_ o: Int) -> UInt32 {
            o + 4 <= b.count ? UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) : 0
        }
        let x86_64: UInt32 = 0x0100_0007, arm64: UInt32 = 0x0100_000C
        switch be32(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:                  // universal file: a list of programs (big-endian headers)
            let count = Int(be32(4)), size = be32(0) == 0xCAFE_BABF ? 32 : 20
            guard count > 0, count < 32 else { return true }
            return (0..<count).contains { [x86_64, arm64].contains(be32(8 + $0 * size)) }
        case 0xCFFA_EDFE: return true                    // 64-bit program (0xFEEDFACF, little-endian)
        case 0xCEFA_EDFE: return false                   // 32-bit program (0xFEEDFACE, little-endian)
        default: return true
        }
    }

    /// A folder with Windows programs and, unless the game is set to Tessera on its own (then Steam may leave the
    /// Mac version's files beside the Windows ones), no Mac program.
    static func isWindowsGame(_ dir: URL, macFilesAllowed: Bool = false) -> Bool {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        // Steam installed the Mac version (which may also carry Windows files from depots both versions share)
        if !macFilesAllowed, top.contains(where: { $0.hasSuffix(".app") }) || !macPrograms(in: dir).isEmpty { return false }
        if top.contains(where: { $0.lowercased().hasSuffix(".exe") }) { return true }
        // Unreal and similar engines keep the program one or two folders down
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        var seen = 0
        for case let url as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            if url.pathExtension == "app" { if macFilesAllowed { walker.skipDescendants(); continue }; return false }
            if url.pathExtension.lowercased() == "exe" { return true }
            seen += 1
            if seen > 4000 { break }
        }
        return false
    }

    /// Flat "key" "value" pairs of a Valve text file (good enough for appmanifest files).
    static func keyValues(_ url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var kv: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: "\"([^\"]+)\"\\s+\"([^\"]*)\"")
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            if kv[k] == nil { kv[k] = ns.substring(with: m.range(at: 2)) }
        }
        return kv
    }
}

/// Per-game options, stored as NAME=value lines that Tessera's launcher applies when Steam starts the game.
struct GameSettings: Equatable {
    enum Graphics: String, CaseIterable, Identifiable {
        case automatic, d3dmetal, dxmt, dxvk, wined3d
        var id: String { rawValue }
        var label: String {
            switch self {
            case .automatic: return "Automatic (recommended)"
            case .d3dmetal: return "D3DMetal"
            case .dxmt: return "DXMT"
            case .dxvk: return "DXVK (Vulkan)"
            case .wined3d: return "WineD3D (OpenGL)"
            }
        }
        var detail: String {
            switch self {
            case .automatic: return "D3DMetal for most games; DXMT for GameMaker games, BeamNG, Konami's Metal Gear collections and 32-bit DirectX 11 games (D3DMetal is 64-bit only); DXVK for Skyrim Special Edition."
            case .d3dmetal: return "Apple's DirectX 11/12 translation. Fastest for most games."
            case .dxmt: return "Open-source DirectX 11 translation to Metal. Try it if a DirectX 11 game misbehaves."
            case .dxvk: return "DirectX 9-11 translated to Vulkan (DXVK for macOS, on its own MoltenVK). For games that crash with D3DMetal and DXMT."
            case .wined3d: return "Wine's own DirectX 9-11 translation. For older games."
            }
        }
    }

    var graphics: Graphics = .automatic
    var showHUD = false
    var metalFX = false
    var raytracing = false
    var steamOverlay = true
    var fullResolution = true   // the launcher's default too: a game's desktop is the screen's largest real mode
    var extra: [(String, String)] = []

    static func == (a: GameSettings, b: GameSettings) -> Bool {
        a.graphics == b.graphics && a.showHUD == b.showHUD && a.metalFX == b.metalFX && a.raytracing == b.raytracing
            && a.steamOverlay == b.steamOverlay && a.fullResolution == b.fullResolution
            && a.extra.map { "\($0.0)=\($0.1)" } == b.extra.map { "\($0.0)=\($0.1)" }
    }

    static func load(_ game: Game) -> GameSettings {
        var s = GameSettings()
        guard let text = try? String(contentsOf: game.settingsFile, encoding: .utf8) else { return s }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]), v = String(line[line.index(after: eq)...])
            switch k {
            case "TESSERA_GRAPHICS": s.graphics = Graphics(rawValue: v) ?? .automatic
            case "MTL_HUD_ENABLED": s.showHUD = v == "1"
            case "D3DM_ENABLE_METALFX": s.metalFX = v == "1"
            case "D3DM_SUPPORT_DXR": s.raytracing = v == "1"
            case "TESSERA_STEAM_OVERLAY": s.steamOverlay = v != "0"
            case "TESSERA_FULL_RESOLUTION": s.fullResolution = v != "0"
            default: s.extra.append((k, v))
            }
        }
        return s
    }

    func save(_ game: Game) throws {
        var lines = ["# Tessera settings for \(game.name) (Steam app \(game.id))"]
        if graphics != .automatic { lines.append("TESSERA_GRAPHICS=\(graphics.rawValue)") }
        if showHUD { lines.append("MTL_HUD_ENABLED=1") }
        if metalFX { lines.append("D3DM_ENABLE_METALFX=1") }
        if raytracing { lines.append("D3DM_SUPPORT_DXR=1") }
        if !steamOverlay { lines.append("TESSERA_STEAM_OVERLAY=0") }
        if !fullResolution { lines.append("TESSERA_FULL_RESOLUTION=0") }
        for (k, v) in extra where !k.isEmpty { lines.append("\(k)=\(v)") }
        try FileManager.default.createDirectory(at: Paths.gameSettings, withIntermediateDirectories: true)
        if lines.count == 1 {
            try? FileManager.default.removeItem(at: game.settingsFile)
        } else {
            try (lines.joined(separator: "\n") + "\n").write(to: game.settingsFile, atomically: true, encoding: .utf8)
        }
    }
}
