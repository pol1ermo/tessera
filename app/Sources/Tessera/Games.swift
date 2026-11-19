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

    /// Installed games whose folder holds Windows programs and no Mac app - the ones Tessera runs.
    static func windowsGames() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default
        for lib in libraries() {
            let apps = lib.appendingPathComponent("steamapps")
            guard let files = try? fm.contentsOfDirectory(atPath: apps.path) else { continue }
            for f in files where f.hasPrefix("appmanifest_") && f.hasSuffix(".acf") {
                guard let kv = keyValues(apps.appendingPathComponent(f)),
                      let id = kv["appid"], let name = kv["name"], let dir = kv["installdir"] else { continue }
                if id == "228980" { continue }      // Steamworks Common Redistributables
                let install = apps.appendingPathComponent("common/\(dir)")
                guard isWindowsGame(install) else { continue }
                let played = Double(kv["LastPlayed"] ?? "").flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                games.append(Game(id: id, name: name, installDir: install,
                                  sizeOnDisk: Int64(kv["SizeOnDisk"] ?? "") ?? 0, lastPlayed: played))
            }
        }
        return games.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
    }

    static func isWindowsGame(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        if top.contains(where: { $0.hasSuffix(".app") }) { return false }
        if top.contains(where: { $0.lowercased().hasSuffix(".exe") }) { return true }
        // Unreal and similar engines keep the program one or two folders down
        guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        var seen = 0
        for case let url as URL in walker {
            if walker.level > 3 { walker.skipDescendants(); continue }
            if url.pathExtension == "app" { return false }
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
        case d3dmetal, dxmt, wined3d
        var id: String { rawValue }
        var label: String {
            switch self {
            case .d3dmetal: return "D3DMetal (recommended)"
            case .dxmt: return "DXMT"
            case .wined3d: return "WineD3D (OpenGL)"
            }
        }
        var detail: String {
            switch self {
            case .d3dmetal: return "Apple's DirectX 11/12 translation. Fastest for most games."
            case .dxmt: return "Open-source DirectX 11 translation to Metal. Try it if a DirectX 11 game misbehaves."
            case .wined3d: return "Wine's own DirectX 9-11 translation. For older games."
            }
        }
    }

    var graphics: Graphics = .d3dmetal
    var showHUD = false
    var metalFX = false
    var raytracing = false
    var extra: [(String, String)] = []

    static func == (a: GameSettings, b: GameSettings) -> Bool {
        a.graphics == b.graphics && a.showHUD == b.showHUD && a.metalFX == b.metalFX && a.raytracing == b.raytracing
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
            case "TESSERA_GRAPHICS": s.graphics = Graphics(rawValue: v) ?? .d3dmetal
            case "MTL_HUD_ENABLED": s.showHUD = v == "1"
            case "D3DM_ENABLE_METALFX": s.metalFX = v == "1"
            case "D3DM_SUPPORT_DXR": s.raytracing = v == "1"
            default: s.extra.append((k, v))
            }
        }
        return s
    }

    func save(_ game: Game) throws {
        var lines = ["# Tessera settings for \(game.name) (Steam app \(game.id))"]
        if graphics != .d3dmetal { lines.append("TESSERA_GRAPHICS=\(graphics.rawValue)") }
        if showHUD { lines.append("MTL_HUD_ENABLED=1") }
        if metalFX { lines.append("D3DM_ENABLE_METALFX=1") }
        if raytracing { lines.append("D3DM_SUPPORT_DXR=1") }
        for (k, v) in extra where !k.isEmpty { lines.append("\(k)=\(v)") }
        try FileManager.default.createDirectory(at: Paths.gameSettings, withIntermediateDirectories: true)
        if lines.count == 1 {
            try? FileManager.default.removeItem(at: game.settingsFile)
        } else {
            try (lines.joined(separator: "\n") + "\n").write(to: game.settingsFile, atomically: true, encoding: .utf8)
        }
    }
}
