// GamesGuard - keeps Steam away from installed Windows games whenever Tessera is not active in it.
//
// Why: the Mac Steam client only keeps a Windows game installed while the compatibility tools are switched on, which
// is what Tessera's library does inside Steam. A Steam that starts WITHOUT that library (Steam.app replaced by a
// fresh download, Tessera removed from Steam, Steam started some other way) decides within a minute or two that
// Windows-only games do not belong on a Mac: its content log says "config changed : removed depots", "Update
// Required", and after an automatic "update" "finished update, 0 mounted depots" - the game's folder is empty.
// Saves survive (they are in the game's Windows folder), but the games have to be downloaded again. Seen on
// 22 Nov 2026: eight games, 97 GB, gone in six minutes.
//
// How: Steam knows a game is installed from <library>/steamapps/appmanifest_<id>.acf. While no Steam with Tessera's
// library is running, the manifests of the games Tessera runs are PARKED in <library>/steamapps/tessera-parked/,
// which Steam does not read; the game folders themselves are never touched. A Steam without Tessera then sees no
// installed Windows games and leaves their files alone.
//   * Steam starts with Tessera's library: the library (tessera_steam.c, before Steam reads anything) moves the
//     manifests back, notes its process in <support>/steam/running/<pid> and starts `run steam-guard <pid>`.
//   * That guard waits for the Steam process to end - quit, crash or kill alike - and parks the manifests again,
//     unless another Steam with Tessera's library is already running (Steam restarting itself).
//   * "Remove from Steam" and Tessera's window park them too (`run park-games`).
// Both sides take the same lock file, so parking and un-parking never interleave.
//
// Which games: every installed game whose folder does not clearly hold a Mac version, and the ones set to Tessera
// one by one in Steam (their Windows version is installed), plus Steam's "Steamworks Common Redistributables"
// (Windows installers that belong to those games) when any is parked. See parkDecision.
import Darwin
import Foundation

enum GamesGuard {
    static let verbs: Set<String> = ["steam-guard", "park-games", "unpark-games", "parked-games"]
    static let folderName = "tessera-parked"
    static let redistributablesID = "228980"
    static let toolNames: Set<String> = ["tessera_proton", "tessera"]

    // HOME, as Tessera's library inside Steam uses it (and so that a test can point both at a scratch folder)
    static let home: String = {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return h }
        return NSHomeDirectory()
    }()
    static var steamData: String { home + "/Library/Application Support/Steam" }
    static var support: String { home + "/Library/Application Support/Tessera" }
    static var runningDir: String { support + "/steam/running" }
    static var lockFile: String { support + "/steam/guard.lock" }

    static func main(_ args: [String]) -> Int32 {
        switch args[0] {
        case "steam-guard":
            guard args.count > 1, let pid = Int32(args[1]) else { return 2 }
            return guardSteam(pid)
        case "park-games" where args.contains("--list"):
            // what would be parked, without doing it
            let setToTessera = gamesSetToTessera()
            for apps in steamAppsFolders() {
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? []).sorted() where isManifest(name) {
                    let kv = keyValues(apps + "/" + name)
                    guard let id = kv["appid"], let dir = kv["installdir"] else { continue }
                    let decision = id == redistributablesID ? (park: true, why: "goes with the parked games")
                        : parkDecision(apps + "/common/" + dir, setToTessera: setToTessera.contains(id))
                    print("\(decision.park ? "park" : "keep")  \(id)  \(kv["name"] ?? "?")  (\(decision.why))")
                }
            }
            return 0
        case "park-games":
            let parked = withLock { () -> Int in
                if let other = steamWithTessera(except: 0) {
                    print("Steam is running with Tessera (process \(other)); nothing parked")
                    return -1
                }
                return park()
            }
            if parked >= 0 { print("parked \(parked)") }
            return 0
        case "unpark-games":
            print("put back \(withLock { unpark() })")
            return 0
        case "parked-games":
            for file in parkedManifests() { print(file) }
            return 0
        default:
            return 2
        }
    }

    // MARK: log (the same file and line shape as Tessera's library inside Steam)

    static func log(_ message: String) {
        let dir = home + "/Library/Logs/Tessera"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(f.string(from: Date()))] [\(getpid())] guard: \(message)\n"
        if let handle = FileHandle(forWritingAtPath: dir + "/steam.log") {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(toFile: dir + "/steam.log", atomically: false, encoding: .utf8)
        }
    }

    // MARK: lock and running Steam processes

    static func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(atPath: support + "/steam", withIntermediateDirectories: true)
        let fd = open(lockFile, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return body()
    }

    static func isSteam(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/steam_osx")
    }

    /// A running Steam process that loaded Tessera's library (it leaves a marker named after its process id), other
    /// than `except`. Markers of processes that are gone are removed.
    static func steamWithTessera(except: Int32) -> Int32? {
        let fm = FileManager.default
        var found: Int32?
        for name in (try? fm.contentsOfDirectory(atPath: runningDir)) ?? [] {
            guard let pid = Int32(name) else { continue }
            if pid == except { continue }
            if isSteam(pid) { found = found ?? pid } else { try? fm.removeItem(atPath: runningDir + "/" + name) }
        }
        return found
    }

    // MARK: Steam's libraries and manifests

    /// Every steamapps folder: Steam's own and the extra library folders (libraryfolders.vdf).
    static func steamAppsFolders() -> [String] {
        var out = [steamData + "/steamapps"]
        for vdf in [steamData + "/steamapps/libraryfolders.vdf", steamData + "/config/libraryfolders.vdf"] {
            guard let text = try? String(contentsOfFile: vdf, encoding: .utf8) else { continue }
            let re = try! NSRegularExpression(pattern: "\"path\"\\s*\"([^\"]+)\"")
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let folder = (ns.substring(with: m.range(at: 1)) as NSString).standardizingPath + "/steamapps"
                if !out.contains(folder) { out.append(folder) }
            }
        }
        return out.filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func isManifest(_ name: String) -> Bool { name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") }

    static func keyValues(_ path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var kv: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: "\"([^\"]+)\"\\s+\"([^\"]*)\"")
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            if kv[k] == nil { kv[k] = ns.substring(with: m.range(at: 2)) }
        }
        return kv
    }

    /// Games set to Tessera one by one in Steam (config.vdf, CompatToolMapping): their Windows version is installed
    /// even where a Mac version exists.
    static func gamesSetToTessera() -> Set<String> {
        guard let text = try? String(contentsOfFile: steamData + "/config/config.vdf", encoding: .utf8),
              let key = text.range(of: "\"CompatToolMapping\"") else { return [] }
        // the block is small and flat: "<id>" { "name" "<tool>" "config" "" "priority" "250" }
        let tail = String(text[key.upperBound...].prefix(200_000))
        let entry = try! NSRegularExpression(pattern: "\"(\\d+)\"\\s*\\{([^{}]*)\\}")
        let name = try! NSRegularExpression(pattern: "\"name\"\\s*\"([^\"]*)\"")
        var out: Set<String> = []
        var depth = 0, end = tail.endIndex
        for i in tail.indices {                      // the mapping block ends where its braces close
            if tail[i] == "{" { depth += 1 } else if tail[i] == "}" { depth -= 1; if depth == 0 { end = tail.index(after: i); break } }
        }
        let block = String(tail[..<end]) as NSString
        for m in entry.matches(in: block as String, range: NSRange(location: 0, length: block.length)) {
            let id = block.substring(with: m.range(at: 1))
            let inner = block.substring(with: m.range(at: 2)) as NSString
            if id != "0", let n = name.firstMatch(in: inner as String, range: NSRange(location: 0, length: inner.length)),
               toolNames.contains(inner.substring(with: n.range(at: 1))) {
                out.insert(id)
            }
        }
        return out
    }

    // Which records are parked. Tessera's window lists a game when it finds a Windows program near the top of its
    // folder; the guard must not miss one, because a missed game is a deleted game. So it is the other way round
    // here: every installed game is parked unless its folder clearly holds a Mac version (and the game is not set
    // to Tessera on its own). A Mac game parked by mistake costs nothing: Steam with Tessera gets every record
    // back before it reads them, and a Steam without Tessera merely does not list that game as installed.
    static func isMachO(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        let b = [UInt8]((try? h.read(upToCount: 8)) ?? Data())
        guard b.count == 8 else { return false }
        let magic = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        let count = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        switch magic {
        case 0xCEFA_EDFE, 0xCFFA_EDFE, 0xFEED_FACE, 0xFEED_FACF: return true
        case 0xCAFE_BABE, 0xCAFE_BABF: return count > 0 && count < 32
        default: return false
        }
    }

    /// A Mac version: an app bundle at the top of the folder or one folder down, the folder itself laid out as a
    /// bundle (Contents/MacOS), or a plain Mac program at the top (Valve's own games: hl2_osx).
    static func hasMacVersion(_ dir: String, top: [String]) -> Bool {
        let fm = FileManager.default
        if top.contains("Contents"), fm.fileExists(atPath: dir + "/Contents/MacOS") { return true }
        for name in top.prefix(400) {
            if name.hasSuffix(".app") { return true }
            if !name.contains("."), isMachO(dir + "/" + name) { return true }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/" + name, isDirectory: &isDir), isDir.boolValue,
               ((try? fm.contentsOfDirectory(atPath: dir + "/" + name)) ?? []).prefix(400).contains(where: { $0.hasSuffix(".app") }) {
                return true
            }
        }
        return false
    }

    /// nil: stays visible (the reason is in `why`); otherwise parked.
    static func parkDecision(_ dir: String, setToTessera: Bool) -> (park: Bool, why: String) {
        guard let top = try? FileManager.default.contentsOfDirectory(atPath: dir), !top.isEmpty else {
            return (false, "nothing installed in its folder")
        }
        if setToTessera { return (true, "set to Tessera in Steam") }
        if hasMacVersion(dir, top: top) { return (false, "Mac version") }
        return (true, "no Mac version in its folder")
    }

    // MARK: park and put back

    static let readMe = """
    Tessera parks the install records ("appmanifest" files) of your Windows games in this folder while Steam is not
    running with Tessera. Steam without Tessera would otherwise decide that Windows games do not belong on a Mac and
    remove their files. The games themselves stay untouched in steamapps/common.

    Tessera puts these files back by itself the moment Steam starts with Tessera. If you no longer use Tessera and
    want Steam to see the games again (it will then remove their files, or offer their Mac versions), move the
    files from here back into the steamapps folder while Steam is closed.

    """

    static func parkedManifests() -> [String] {
        var out: [String] = []
        for apps in steamAppsFolders() {
            let parked = apps + "/" + folderName
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: parked)) ?? []).sorted() where isManifest(name) {
                out.append(parked + "/" + name)
            }
        }
        return out
    }

    /// A parked or visible copy that lost against a newer one is kept, never deleted.
    static func setAside(_ path: String, in parked: String) {
        let fm = FileManager.default
        let older = parked + "/older"
        try? fm.createDirectory(atPath: older, withIntermediateDirectories: true)
        let name = (path as NSString).lastPathComponent
        try? fm.moveItem(atPath: path, toPath: older + "/\(name).\(Int(Date().timeIntervalSince1970))")
    }

    /// Moves the manifests of the games Tessera runs out of Steam's sight. Call with the lock held and no Steam with
    /// Tessera's library running. Returns how many were parked.
    @discardableResult static func park() -> Int {
        let fm = FileManager.default
        let setToTessera = gamesSetToTessera()
        var count = 0
        for apps in steamAppsFolders() {
            let parked = apps + "/" + folderName
            var names: [String] = []
            var redistributables: String?
            for name in ((try? fm.contentsOfDirectory(atPath: apps)) ?? []) where isManifest(name) {
                let kv = keyValues(apps + "/" + name)
                guard let id = kv["appid"], let dir = kv["installdir"] else { continue }
                if id == redistributablesID { redistributables = name; continue }
                if parkDecision(apps + "/common/" + dir, setToTessera: setToTessera.contains(id)).park { names.append(name) }
            }
            let alreadyParked = ((try? fm.contentsOfDirectory(atPath: parked)) ?? []).contains(where: isManifest)
            if let r = redistributables, !names.isEmpty || alreadyParked { names.append(r) }
            guard !names.isEmpty else { continue }
            try? fm.createDirectory(atPath: parked, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: parked + "/Read me.txt") {
                try? readMe.write(toFile: parked + "/Read me.txt", atomically: true, encoding: .utf8)
            }
            for name in names {
                let from = apps + "/" + name, to = parked + "/" + name
                if fm.fileExists(atPath: to) { setAside(to, in: parked) }      // Steam's current file is the newer one
                if rename(from, to) == 0 { count += 1 } else { log("could not park \(name): \(String(cString: strerror(errno)))") }
            }
        }
        return count
    }

    /// Moves parked manifests back. Call with the lock held. Returns how many were put back. Where Steam has made a
    /// manifest of its own in the meantime, Steam's stays and the parked one is set aside.
    @discardableResult static func unpark() -> Int {
        let fm = FileManager.default
        var count = 0
        for apps in steamAppsFolders() {
            let parked = apps + "/" + folderName
            for name in ((try? fm.contentsOfDirectory(atPath: parked)) ?? []) where isManifest(name) {
                let from = parked + "/" + name, to = apps + "/" + name
                if fm.fileExists(atPath: to) { setAside(from, in: parked); continue }
                if rename(from, to) == 0 { count += 1 } else { log("could not put back \(name): \(String(cString: strerror(errno)))") }
            }
        }
        return count
    }

    // MARK: the guard process

    /// Waits for a Steam process (one that loaded Tessera's library) to end and then parks the manifests, unless
    /// another Steam with Tessera's library is running by then.
    static func guardSteam(_ pid: Int32) -> Int32 {
        // on its own: no terminal, not ended with the session's other programs before it has done its work
        setsid()
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)
        guard isSteam(pid) else { return 1 }
        let queue = kqueue()
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD), fflags: UInt32(NOTE_EXIT),
                            data: 0, udata: nil)
        var watching = queue >= 0 && kevent(queue, &change, 1, nil, 0, nil) == 0
        while isSteam(pid) {
            if watching {
                var event = kevent()
                var wait = timespec(tv_sec: 5, tv_nsec: 0)      // and look again every 5 s, should the event be missed
                if kevent(queue, nil, 0, &event, 1, &wait) < 0, errno != EINTR { watching = false }
            } else {
                usleep(500_000)
            }
        }
        withLock {
            try? FileManager.default.removeItem(atPath: runningDir + "/\(pid)")
            if let other = steamWithTessera(except: pid) {
                log("Steam (process \(pid)) has ended; another Steam with Tessera runs (process \(other)), nothing parked")
            } else {
                let count = park()
                log("Steam (process \(pid)) has ended; \(count) install record\(count == 1 ? "" : "s") of Windows games parked")
            }
        }
        return 0
    }
}
