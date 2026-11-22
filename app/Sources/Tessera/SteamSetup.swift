import Foundation

/// What a command line tool printed, gathered while it runs.
private final class ToolOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Runs a command line tool and returns its exit status and combined output.
///
/// `output: false` is for a tool that starts programs which outlive it (Steam's own "-shutdown" call can): they
/// inherit the pipe, and reading it to its end would wait for them. Output is gathered while the tool runs, so a
/// tool that prints more than a pipe holds finishes too. A tool that is still running at the timeout is stopped
/// (asked first, then forced) and only then asked for its status: up to 1.2.11.1 the status was read from a tool
/// that had not ended yet, which closed Tessera with an exception.
/// `errors: false` leaves what the tool writes to its error stream out of the output (a download's warnings would
/// otherwise land in the middle of the data).
@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 120, output wanted: Bool = true,
         errors: Bool = true) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    let collected = ToolOutput()
    if wanted {
        p.standardOutput = pipe
        if errors { p.standardError = pipe } else { p.standardError = FileHandle.nullDevice }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // nothing more comes once the tool has closed its end: stop listening (an empty read repeats for ever)
            if chunk.isEmpty { handle.readabilityHandler = nil } else { collected.add(chunk) }
        }
    } else {
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
    }
    do { try p.run() } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        return (-1, "\(error)")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning {
        p.terminate()
        let grace = Date().addingTimeInterval(2)
        while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
    }
    if wanted {
        Thread.sleep(forTimeInterval: 0.05)     // what it printed last
        pipe.fileHandleForReading.readabilityHandler = nil
    }
    return (p.terminationStatus, collected.text)
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
    /// Steam maps a game's Windows save folders (Saved Games, Documents, AppData) into its prefix, which Steam Cloud
    /// needs, only for compatibility tools whose internal name contains "proton" (Steam checks the name when it
    /// registers a tool). Tessera's tool is registered as "tessera_proton"; up to 1.2.6 it was "tessera". People see
    /// "Tessera" either way (display_name).
    static let toolName = "tessera_proton"
    static let legacyToolNames = ["tessera"]
    /// Valve's original files, kept per Steam.app location ("/Applications/Steam.app" -> "Applications_Steam.app").
    static var backupDir: URL {
        let key = Paths.steamApp.path.split(separator: "/").joined(separator: "_")
        return Paths.backups.appendingPathComponent(key)
    }

    static func state() -> State {
        let fm = FileManager.default
        if Bundle.main.bundlePath.contains("/AppTranslocation/") { return .notInApplications }
        guard fm.fileExists(atPath: Paths.steamApp.path) else { return .steamMissing }
        if steamAppIsIncomplete {
            return .needsRepair("Steam.app is missing its Info.plist (removing Tessera was stopped half-way by macOS); Repair puts Valve's file back")
        }
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
        if CompatMappings.uses(legacyToolNames) {
            return .needsRepair("Steam has to restart once to finish the update (Steam Cloud saves)")
        }
        if !rosettaInstalled {
            return .needsRepair("Apple's Rosetta 2 is not installed; Windows games run through it. Repair installs it (you agree to Apple's licence for Rosetta)")
        }
        return .installed
    }

    static func steamEnvironment() -> [String: String] {
        let plist = Paths.steamApp.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else { return [:] }
        return dict["LSEnvironment"] as? [String: String] ?? [:]
    }

    /// The Steam client is running: a process whose program is steam_osx, other than the short-lived "-shutdown"
    /// call of the same program. (Up to 1.2.11.1 any process with the client's path anywhere in its command line
    /// counted - a Terminal command, a script - and "quit Steam" then waited a minute for a program that was not
    /// Steam, or called "steam_osx -shutdown" with no Steam running, which starts Steam.)
    // MARK: - the games guard (tool/Sources/tessera-run/GamesGuard.swift tells the whole story)
    //
    // A Steam without Tessera's library removes the files of installed Windows games. While no Steam with the library
    // runs, the games' install records are parked in <library>/steamapps/tessera-parked, where Steam does not look.
    // The library puts them back when Steam starts and starts a guard that parks them when Steam ends; these calls
    // are for the moments Tessera's window is involved.

    /// The launcher that carries the guard: Steam's copy, or the one inside this app before the first set-up.
    private static var guardTool: URL {
        let installed = Paths.compatTool.appendingPathComponent("run")
        return FileManager.default.isExecutableFile(atPath: installed.path) ? installed : Paths.bundledCompatTool.appendingPathComponent("run")
    }

    /// Parks the install records of Windows games unless a Steam with Tessera's library is running.
    static func parkGames() {
        run(guardTool.path, ["park-games"], timeout: 60)
    }

    /// Parking only helps when the Steam that starts next either has no Tessera library (then the games need the
    /// protection) or has the library of this version, which puts the records back; an older library would not.
    static var parkingIsSafe: Bool {
        guard steamEnvironment()[insertKey] != nil else { return true }
        return FileManager.default.contentsEqual(atPath: Paths.steamLibrary.path, andPath: Paths.bundledSteamLibrary.path)
    }

    /// Steam's own processes: the program is steam_osx (a helper merely started from that folder is not), and the
    /// short-lived `-shutdown` call that tells a running Steam to quit does not count.
    static var steamProcesses: [Int32] {
        func table(_ column: String) -> [Int32: String] {
            var rows: [Int32: String] = [:]
            for line in run("/bin/ps", ["-axww", "-o", "pid=,\(column)="]).output.split(whereSeparator: \.isNewline) {
                let trimmed = line.drop(while: { $0 == " " })
                guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
                rows[pid] = trimmed[space...].trimmingCharacters(in: .whitespaces)
            }
            return rows
        }
        let programs = table("comm"), commands = table("args")
        return programs.filter { pid, program in
            (program == "steam_osx" || program.hasSuffix("/steam_osx")) && !(commands[pid] ?? "").hasSuffix(" -shutdown")
        }.keys.sorted()
    }

    /// A Steam that is running with a Tessera library from before the guard existed (Tessera was just updated) gets
    /// its guard now, so the records are parked when that Steam ends.
    static func guardRunningSteam() {
        guard steamEnvironment()[insertKey]?.contains(Paths.steamLibrary.path) == true else { return }
        let running = Paths.steamLibrary.deletingLastPathComponent().appendingPathComponent("running")
        let fm = FileManager.default
        for pid in steamProcesses where !fm.fileExists(atPath: running.appendingPathComponent("\(pid)").path) {
            try? fm.createDirectory(at: running, withIntermediateDirectories: true)
            fm.createFile(atPath: running.appendingPathComponent("\(pid)").path, contents: nil)
            let task = Process()
            task.executableURL = guardTool
            task.arguments = ["steam-guard", "\(pid)"]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()                       // it detaches itself and outlives this app
        }
    }

    static var steamIsRunning: Bool { !steamProcesses.isEmpty }

    /// Asks the running Steam client to quit and waits for it.
    static func quitSteam() -> Bool {
        guard steamIsRunning else { return true }
        run(Paths.steamClient.path, ["-shutdown"], timeout: 10, output: false)
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
        // Games still mapped to the earlier name keep their tool until Steam is closed and install() renames them
        // (Steam rewrites its settings when it quits, so they are not edited while it runs).
        if CompatMappings.uses(legacyToolNames) { try registerTool(as: legacyToolNames[0]) }
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
        guardRunningSteam()
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
        try installRosetta()
        guard quitSteam() else { throw SetupError.steamRunning }
        try CompatMappings.renameTool(from: legacyToolNames, to: toolName)
        try installFiles()
        try patchSteamApp()
        if setDefaultTool {
            try CompatMappings.setDefaultTool(toolName, replacingOtherTools: useForAllWindowsGames)
        }
    }

    /// Steam downloads the Windows version of a game whose Mac version cannot run and plays it through Tessera.
    static func playWindowsVersion(appID: String) throws {
        guard quitSteam() else { throw SetupError.steamRunning }
        try CompatMappings.useTool(toolName, forApp: appID)
    }

    /// Wine runs Intel code through Apple's Rosetta 2. Apple-silicon Macs get it only when something asks for it, and
    /// Steam runs natively, so without it every Windows game fails to start whatever the graphics. Apple's
    /// softwareupdate installs it without an administrator password. TESSERA_TEST_NO_ROSETTA=1 pretends it is missing.
    static var rosettaInstalled: Bool {
        ProcessInfo.processInfo.environment["TESSERA_TEST_NO_ROSETTA"] != "1"
            && FileManager.default.fileExists(atPath: rosettaRuntime)
    }
    static let rosettaRuntime = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    static func installRosetta() throws {
        guard !rosettaInstalled else { return }
        let result = run("/usr/sbin/softwareupdate", ["--install-rosetta", "--agree-to-license"], timeout: 600)
        guard FileManager.default.fileExists(atPath: rosettaRuntime) else {
            throw SetupError.failed("Installing Apple's Rosetta 2 failed (softwareupdate exit \(result.status)). In Terminal: softwareupdate --install-rosetta")
        }
    }

    /// The internal name the compatibility tool is registered under in Steam (compatibilitytool.vdf).
    static func registerTool(as name: String) throws {
        let vdf = Paths.compatTool.appendingPathComponent("compatibilitytool.vdf")
        let text = try String(contentsOf: vdf, encoding: .utf8)
        try text.replacingOccurrences(of: "\"\(toolName)\"", with: "\"\(name)\"").write(to: vdf, atomically: true, encoding: .utf8)
    }

    static func patchSteamApp() throws {
        let fm = FileManager.default
        let contents = Paths.steamApp.appendingPathComponent("Contents")
        let plistURL = contents.appendingPathComponent("Info.plist")
        // Back up Valve's originals whenever Steam.app is Valve's own: a backup from an earlier setup may be older than
        // the Steam launcher now (Steam updates it), and "Remove from Steam" would put old files back. Steam.app
        // already set up keeps its backup (a second install must not back up our own changes).
        if steamAppIsIncomplete { try restoreOriginals() }
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
        // Set up already, with a valid signature: nothing to change. Signing again would give Steam.app a new
        // signature, and macOS would ask again for permissions it granted to the old one (the microphone).
        if env[insertKey] == Paths.steamLibrary.path,
           run("/usr/bin/codesign", ["--verify", Paths.steamApp.path]).status == 0 {
            registerWithLaunchServices()
            return
        }
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
        // Steam without Tessera would remove the files of installed Windows games: their install records are parked
        // (steamapps/tessera-parked) before Steam can start again; a later set-up brings them back
        parkGames()
        // Steam may have updated its launcher since: then it is Valve's original already and the old backup is stale.
        // A Steam.app without its Info.plist is not that case: the backup is what makes it whole again.
        if steamEnvironment()[insertKey] != nil || steamAppIsIncomplete {
            try restoreOriginals()
            registerWithLaunchServices()
        }
        try? fm.removeItem(at: backupDir)
        try? CompatMappings.removeTool([toolName] + legacyToolNames)
        // the copies of Valve's Windows Steam files the game launcher put into Steam's legacycompat folder
        // (ValveFiles.swift); a file of another size there is someone else's and stays
        let legacy = Paths.steamClient.deletingLastPathComponent().appendingPathComponent("legacycompat")
        for file in valveFiles {
            let copy = legacy.appendingPathComponent(file.name), own = valveFilesFolder.appendingPathComponent(file.name)
            if let a = (try? fm.attributesOfItem(atPath: copy.path))?[.size] as? NSNumber,
               let b = (try? fm.attributesOfItem(atPath: own.path))?[.size] as? NSNumber, a == b {
                try? fm.removeItem(at: copy)
            }
        }
        // Steam no longer loads them; per-game settings and logs stay in case Tessera is set up again
        for item in [Paths.steamLibrary.deletingLastPathComponent(), Paths.compatRoot, Paths.runtimeLink, Paths.prefixTemplates] {
            try? fm.removeItem(at: item)
        }
    }

    /// Steam.app without its Info.plist: Tessera up to 1.2.11 deleted each of Valve's files before writing the original
    /// back, and where macOS refused the write (App Management), Steam.app was left without it and could not open.
    static var steamAppIsIncomplete: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Paths.steamApp.appendingPathComponent("Contents/MacOS").path)
            && !fm.fileExists(atPath: Paths.steamApp.appendingPathComponent("Contents/Info.plist").path)
    }

    /// Puts Valve's Info.plist, signature and binary back. Every file is first copied next to its place; only when
    /// all three copies are there are they swapped in. If macOS refuses (App Management), Steam.app stays exactly as
    /// it was, the backup stays, and the person is told which switch to turn on.
    static func restoreOriginals() throws {
        let fm = FileManager.default
        let contents = Paths.steamApp.appendingPathComponent("Contents")
        guard fm.fileExists(atPath: backupDir.appendingPathComponent("Info.plist").path) else {
            throw SetupError.failed(steamAppIsIncomplete
                ? "Steam.app is incomplete (its Info.plist is missing) and there is no backup of Valve's files. Install Steam again from store.steampowered.com/about, then set up Tessera."
                : "No backup of Steam's original files was found")
        }
        var staged: [(copy: URL, target: URL)] = []
        do {
            for (name, dst) in [("Info.plist", "Info.plist"), ("_CodeSignature", "_CodeSignature"), ("steam_osx", "MacOS/steam_osx")] {
                let target = contents.appendingPathComponent(dst)
                let copy = target.deletingLastPathComponent().appendingPathComponent(".tessera-restore-\(target.lastPathComponent)")
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: backupDir.appendingPathComponent(name), to: copy)
                staged.append((copy, target))
            }
            for (copy, target) in staged {
                if fm.fileExists(atPath: target.path) {
                    _ = try fm.replaceItemAt(target, withItemAt: copy)
                } else {
                    try fm.moveItem(at: copy, to: target)
                }
            }
        } catch let error as NSError {
            for (copy, _) in staged { try? fm.removeItem(at: copy) }
            if isPermissionError(error) { throw SetupError.appManagement }
            throw error
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

    /// One game plays through this tool although Steam has a Mac version of it: Steam then downloads its Windows
    /// version (Steam must be closed).
    static func useTool(_ tool: String, forApp id: String) throws {
        try edit { m in m[id] = Mapping(name: tool, config: "", priority: "250") }
    }

    /// Whether any game is mapped to one of these tool names.
    static func uses(_ tools: [String]) -> Bool {
        read().values.contains { tools.contains($0.name) }
    }

    /// Moves every game mapped to one of the old tool names to the new one (Steam must be closed).
    static func renameTool(from old: [String], to new: String) throws {
        guard uses(old) else { return }
        try edit { m in
            for (id, var entry) in m where old.contains(entry.name) {
                entry.name = new
                m[id] = entry
            }
        }
    }

    static func removeTool(_ tools: [String]) throws {
        let previous = (try? JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: previousChoicesFile))) ?? [:]
        try edit { m in
            for (id, entry) in m where tools.contains(entry.name) {
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
