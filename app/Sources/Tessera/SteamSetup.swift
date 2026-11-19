import Foundation

/// Runs a command line tool and returns its exit status and combined output.
@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 120) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning { p.terminate() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Installs Tessera into the macOS Steam client and takes it out again.
///
/// Steam.app's Info.plist gets one extra start-up variable that loads Tessera's library; because Valve's signature
/// forbids extra libraries, the app is then signed again locally. The original Info.plist, signature and binary are
/// backed up first, and removing Tessera puts exactly those files back.
enum SteamSetup {
    enum State: Equatable {
        case notInApplications      // opened straight from a download: macOS runs it from a temporary copy
        case steamMissing
        case notInstalled
        case installed
        case needsRepair(String)
    }

    static let insertKey = "DYLD_INSERT_LIBRARIES"
    /// Valve's original files, kept per Steam.app location ("/Applications/Steam.app" -> "Applications_Steam.app").
    static var backupDir: URL {
        let key = Paths.steamApp.path.split(separator: "/").joined(separator: "_")
        return Paths.backups.appendingPathComponent(key)
    }

    static func state() -> State {
        let fm = FileManager.default
        if Bundle.main.bundlePath.contains("/AppTranslocation/") { return .notInApplications }
        guard fm.fileExists(atPath: Paths.steamApp.path) else { return .steamMissing }
        let env = steamEnvironment()
        guard let insert = env[insertKey], insert.contains(Paths.steamLibrary.path) else { return .notInstalled }
        if !fm.fileExists(atPath: Paths.steamLibrary.path) { return .needsRepair("Tessera's Steam library is missing") }
        if !fm.isExecutableFile(atPath: Paths.compatTool.appendingPathComponent("run").path) {
            return .needsRepair("Tessera's compatibility tool is missing")
        }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.runtimeLink.path)) != Paths.bundledRuntime.path {
            return .needsRepair("the Windows runtime link points to an older copy of Tessera")
        }
        if !fm.fileExists(atPath: Paths.runtimeLink.appendingPathComponent("bin/wineloader").path) {
            return .needsRepair("the Windows runtime is missing")
        }
        return .installed
    }

    static func steamEnvironment() -> [String: String] {
        let plist = Paths.steamApp.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return [:] }
        return dict["LSEnvironment"] as? [String: String] ?? [:]
    }

    static var steamIsRunning: Bool {
        run("/usr/bin/pgrep", ["-f", "Steam.AppBundle/Steam/Contents/MacOS/steam_osx"]).status == 0
    }

    /// Asks the running Steam client to quit and waits for it.
    static func quitSteam() -> Bool {
        guard steamIsRunning else { return true }
        run(Paths.steamClient.path, ["-shutdown"], timeout: 10)
        for _ in 0..<60 {
            if !steamIsRunning { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return !steamIsRunning
    }

    static func openSteam() {
        run("/usr/bin/open", [Paths.steamApp.path])
    }

    // MARK: - files Tessera keeps outside its app bundle

    static func installFiles() throws {
        let fm = FileManager.default
        for dir in [Paths.steamLibrary.deletingLastPathComponent(), Paths.compatRoot, Paths.gameSettings, Paths.backups, Paths.logs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try replace(Paths.steamLibrary, with: Paths.bundledSteamLibrary)
        try replace(Paths.compatTool, with: Paths.bundledCompatTool)
        try? fm.removeItem(at: Paths.runtimeLink)
        try fm.createSymbolicLink(at: Paths.runtimeLink, withDestinationURL: Paths.bundledRuntime)
        // A downloaded app arrives quarantined, and copies keep the flag. macOS stops a quarantined program or library
        // that Steam starts or loads (the Steam library, the launcher, Wine and D3DMetal) with a "Not Opened" prompt,
        // so the flag goes from the runtime and from the copies (the person already approved Tessera to open it).
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Paths.bundledRuntime.path,
                               Paths.steamLibrary.deletingLastPathComponent().path, Paths.compatTool.path])
    }

    /// Runs when the app opens. After an update the app's files are new (and quarantined again when downloaded) while
    /// Steam still uses the earlier copies, so the copies are refreshed when they differ and the flag is cleared.
    static func syncAfterUpdate() {
        guard steamEnvironment()[insertKey]?.contains(Paths.steamLibrary.path) == true,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: Paths.runtimeLink.path)) == Paths.bundledRuntime.path
        else { return }
        let fm = FileManager.default
        let current = fm.contentsEqual(atPath: Paths.steamLibrary.path, andPath: Paths.bundledSteamLibrary.path)
            && fm.contentsEqual(atPath: Paths.compatTool.appendingPathComponent("run").path,
                                andPath: Paths.bundledCompatTool.appendingPathComponent("run").path)
        if !current { try? installFiles() }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", Paths.bundledRuntime.path,
                               Paths.steamLibrary.deletingLastPathComponent().path, Paths.compatTool.path])
    }

    private static func replace(_ dst: URL, with src: URL) throws {
        let fm = FileManager.default
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).new")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: tmp, to: dst)
    }

    // MARK: - Steam.app

    enum SetupError: LocalizedError {
        case steamRunning, appManagement, failed(String)
        var errorDescription: String? {
            switch self {
            case .steamRunning: return "Steam is still running. Quit Steam and try again."
            case .appManagement:
                return "macOS needs your OK first: in System Settings › Privacy & Security › App Management, turn on Tessera, then set up again."
            case .failed(let why): return why
            }
        }
    }

    static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError { return true }
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return posix.domain == NSPOSIXErrorDomain && (posix.code == Int(EPERM) || posix.code == Int(EACCES))
    }

    /// System Settings › Privacy & Security › App Management
    static let appManagementSettings = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles")!

    static func install(useForAllWindowsGames: Bool, setDefaultTool: Bool = true) throws {
        guard quitSteam() else { throw SetupError.steamRunning }
        try installFiles()
        try patchSteamApp()
        if setDefaultTool {
            try CompatMappings.setDefaultTool("tessera", replacingOtherTools: useForAllWindowsGames)
        }
    }

    static func patchSteamApp() throws {
        let fm = FileManager.default
        let contents = Paths.steamApp.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Info.plist")
        // Back up Valve's originals whenever Steam.app is Valve's own: a backup from an earlier setup may be older than
        // the Steam launcher now (Steam updates it), and "Remove from Steam" would put old files back. Steam.app
        // already set up keeps its backup (a second install must not back up our own changes).
        let steamIsOriginal = steamEnvironment()[insertKey] == nil
        if steamIsOriginal { try? fm.removeItem(at: backupDir) }
        if !fm.fileExists(atPath: backupDir.appendingPathComponent("Info.plist").path) {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try fm.copyItem(at: plistURL, to: backupDir.appendingPathComponent("Info.plist"))
            try fm.copyItem(at: contents.appendingPathComponent("_CodeSignature"), to: backupDir.appendingPathComponent("_CodeSignature"))
            try fm.copyItem(at: contents.appendingPathComponent("MacOS/steam_osx"), to: backupDir.appendingPathComponent("steam_osx"))
        }
        guard let data = try? Data(contentsOf: plistURL),
              var dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SetupError.failed("Steam's Info.plist could not be read")
        }
        var env = dict["LSEnvironment"] as? [String: String] ?? [:]
        env[insertKey] = Paths.steamLibrary.path
        dict["LSEnvironment"] = env
        do {
            let out = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try out.write(to: plistURL)
        } catch let error as NSError where Self.isPermissionError(error) {
            // macOS "App Management": an app may change another developer's app only once the user allows it
            throw SetupError.appManagement
        }
        // no hardened runtime: it would make macOS ignore the start-up variable
        let sign = run("/usr/bin/codesign", ["--force", "--sign", "-", "--preserve-metadata=identifier", Paths.steamApp.path])
        guard sign.status == 0 else { throw SetupError.failed("Steam could not be signed: \(sign.output)") }
        registerWithLaunchServices()
    }

    static func uninstall() throws {
        guard quitSteam() else { throw SetupError.steamRunning }
        let fm = FileManager.default
        let contents = Paths.steamApp.appendingPathComponent("Contents")
        // Steam may have updated its launcher since: then it is Valve's original already and the old backup is stale
        if steamEnvironment()[insertKey] != nil {
            guard fm.fileExists(atPath: backupDir.appendingPathComponent("Info.plist").path) else {
                throw SetupError.failed("No backup of Steam's original files was found")
            }
            for (name, dst) in [("Info.plist", "Info.plist"), ("_CodeSignature", "_CodeSignature"), ("steam_osx", "MacOS/steam_osx")] {
                let target = contents.appendingPathComponent(dst)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: backupDir.appendingPathComponent(name), to: target)
            }
            registerWithLaunchServices()
        }
        try? fm.removeItem(at: backupDir)
        try? CompatMappings.removeTool("tessera")
        // Steam no longer loads them; per-game settings and logs stay in case Tessera is set up again
        for item in [Paths.steamLibrary.deletingLastPathComponent(), Paths.compatRoot, Paths.runtimeLink, Paths.prefixTemplates] {
            try? fm.removeItem(at: item)
        }
    }

    private static func registerWithLaunchServices() {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        run(lsregister, ["-f", Paths.steamApp.path])
    }
}

/// Steam's per-game compatibility tool choices (config/config.vdf, "CompatToolMapping"). AppID 0 means "every
/// other title". Steam rewrites config.vdf when it quits, so these edits are made only while Steam is closed.
enum CompatMappings {
    struct Mapping { var name: String; var config: String; var priority: String }

    static func read() -> [String: Mapping] {
        guard let s = try? String(contentsOf: Paths.steamConfig, encoding: .utf8), let block = findBlock(s, "CompatToolMapping") else { return [:] }
        return parse(String(s[block]))
    }

    /// The choices Tessera replaced, so "Remove from Steam" can put them back:
    /// { app id: [name, config, priority] } - an empty list means there was no choice for that id.
    static var previousChoicesFile: URL { Paths.backups.appendingPathComponent("compat-mappings-before-tessera.json") }

    static func setDefaultTool(_ tool: String, replacingOtherTools: Bool) throws {
        try edit { m in
            var previous = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: previousChoicesFile))) ?? [:]
            func remember(_ id: String) {
                guard previous[id] == nil else { return }       // keep the oldest choice across repeated setups
                if let e = m[id], e.name != tool { previous[id] = [e.name, e.config, e.priority] }
                else if m[id] == nil { previous[id] = [] }
            }
            remember("0")
            m["0"] = Mapping(name: tool, config: "", priority: "75")
            if replacingOtherTools {
                // games pointed at another add-on tool (not Valve's own Proton/runtime tools) move to Tessera
                for (id, var entry) in m where !entry.name.isEmpty && entry.name != tool
                    && !entry.name.hasPrefix("proton") && !entry.name.hasPrefix("steamlinuxruntime") {
                    remember(id)
                    entry.name = tool
                    m[id] = entry
                }
            }
            try? FileManager.default.createDirectory(at: Paths.backups, withIntermediateDirectories: true)
            try? JSONEncoder().encode(previous).write(to: previousChoicesFile)
        }
    }

    static func removeTool(_ tool: String) throws {
        let previous = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: previousChoicesFile))) ?? [:]
        try edit { m in
            for (id, entry) in m where entry.name == tool {
                if let p = previous[id], p.count == 3 {
                    m[id] = Mapping(name: p[0], config: p[1], priority: p[2])     // the user's earlier choice
                } else {
                    m.removeValue(forKey: id)
                }
            }
        }
        try? FileManager.default.removeItem(at: previousChoicesFile)
    }

    private static func edit(_ change: (inout [String: Mapping]) -> Void) throws {
        let url = Paths.steamConfig
        guard var s = try? String(contentsOf: url, encoding: .utf8) else { return }
        let backup = Paths.backups.appendingPathComponent("config.vdf.before-tessera")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.createDirectory(at: Paths.backups, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        if findBlock(s, "CompatToolMapping") == nil {
            // first mapping ever: create the block inside Software/Valve/Steam
            guard let steam = findBlock(s, "Steam") else { return }
            s.insert(contentsOf: "\n\t\t\t\t\"CompatToolMapping\"\n\t\t\t\t{\n\t\t\t\t}\n", at: s.index(after: steam.lowerBound))
        }
        guard let block = findBlock(s, "CompatToolMapping") else { return }
        var mappings = parse(String(s[block]))
        change(&mappings)
        let lineStart = s[..<block.lowerBound].lastIndex(of: "\n").map { s.index(after: $0) } ?? s.startIndex
        let indent = s[lineStart..<block.lowerBound].prefix { $0 == "\t" }.count
        let t = String(repeating: "\t", count: indent + 1)
        var body = "{\n"
        for id in mappings.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            let m = mappings[id]!
            body += "\(t)\"\(id)\"\n\(t){\n\(t)\t\"name\"\t\t\"\(m.name)\"\n\(t)\t\"config\"\t\t\"\(m.config)\"\n\(t)\t\"priority\"\t\t\"\(m.priority)\"\n\(t)}\n"
        }
        body += String(repeating: "\t", count: indent) + "}"
        s.replaceSubrange(block, with: body)
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The range of the `{ ... }` that follows `"name"`.
    private static func findBlock(_ s: String, _ name: String) -> Range<String.Index>? {
        guard let key = s.range(of: "\"\(name)\"") else { return nil }
        var i = key.upperBound
        while i < s.endIndex, s[i] != "{" {
            if !s[i].isWhitespace { return nil }
            i = s.index(after: i)
        }
        guard i < s.endIndex else { return nil }
        var depth = 0, inString = false
        var j = i
        while j < s.endIndex {
            let c = s[j]
            if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1; if depth == 0 { return i..<s.index(after: j) } }
            }
            j = s.index(after: j)
        }
        return nil
    }

    private static func parse(_ block: String) -> [String: Mapping] {
        var out: [String: Mapping] = [:]
        let pattern = try! NSRegularExpression(pattern: "\"(\\d+)\"\\s*\\{([^{}]*)\\}")
        let kvPattern = try! NSRegularExpression(pattern: "\"([^\"]+)\"\\s*\"([^\"]*)\"")
        let ns = block as NSString
        for m in pattern.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2)) as NSString
            var kv: [String: String] = [:]
            for k in kvPattern.matches(in: inner as String, range: NSRange(location: 0, length: inner.length)) {
                kv[inner.substring(with: k.range(at: 1))] = inner.substring(with: k.range(at: 2))
            }
            out[id] = Mapping(name: kv["name"] ?? "", config: kv["config"] ?? "", priority: kv["priority"] ?? "250")
        }
        return out
    }
}
