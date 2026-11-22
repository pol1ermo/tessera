import AppKit
import CryptoKit
import Foundation

/// A release as its update.json describes it (packaging/update-manifest.swift writes and signs that file).
struct UpdateManifest: Equatable {
    let version: String         // "1.3.0"
    let build: String           // "202611220310"
    let dmg: String             // "Tessera-1.3.0.dmg"
    let size: Int64
    let sha256: String
    let minimumSystemVersion: String
    let notes: String
    let signature: String
}

/// Updating Tessera from inside the app.
///
/// Every release on GitHub carries a small file, update.json: version, the disk image's name, size and SHA-256, and
/// a signature over those made with a key that only the release Mac holds. Tessera reads that file from the latest
/// release, and when it names a newer version it downloads the disk image, checks size, SHA-256 and signature, copies
/// the new Tessera.app next to the running one, checks the copy's own code signature and version, and swaps the two
/// once Tessera has quit. Then it opens again; what Steam uses of Tessera is refreshed at that start, as after a
/// manual update (SteamSetup.syncAfterUpdate). Steam.app is not touched, so macOS asks for nothing.
///
/// TESSERA_UPDATE_FEED points the check at another update.json (a folder with update.json and the disk image, for
/// testing: file:///…/update.json or http://localhost…).
enum Updater {
    /// The public half of the release key (update-manifest keygen)
    static let publicKey = "qlR+GK0lGkw/NKxmrT0JoIBtuueiTvSWfe1khE+d8xI="
    static let defaultFeed = "https://github.com/pol1ermo/tessera/releases/latest/download/update.json"
    static let releasesPage = URL(string: "https://github.com/pol1ermo/tessera/releases/latest")!

    static var feed: String {
        if let custom = ProcessInfo.processInfo.environment["TESSERA_UPDATE_FEED"], !custom.isEmpty { return custom }
        return defaultFeed
    }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var currentBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
    static let downloads = Paths.home.appendingPathComponent("Library/Caches/Tessera/update")
    static var logFile: URL { Paths.logs.appendingPathComponent("update.log") }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - is there a newer version?

    /// "1.2.11.1" < "1.3.0": compared number by number, a missing number counts as 0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Reads update.json from the latest release and checks it is well-formed and signed by the release key.
    static func fetchManifest() throws -> UpdateManifest {
        let fetched = run("/usr/bin/curl", ["-fsSL", "--retry", "2", "--connect-timeout", "15", "--max-time", "40"] + httpsOnly + [feed],
                          timeout: 60, errors: false)
        guard fetched.status == 0 else {
            if [6, 7, 28, 35].contains(fetched.status) { throw Failure("GitHub could not be reached (no internet?)") }
            if fetched.status == 22 { throw Failure("the latest release has no update information") }
            throw Failure("the update check failed (curl \(fetched.status))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(fetched.output.utf8)) as? [String: Any],
              let version = json["version"] as? String, let build = json["build"] as? String,
              let dmg = json["dmg"] as? String, let size = (json["size"] as? NSNumber)?.int64Value,
              let sha = json["sha256"] as? String, let signature = json["signature"] as? String
        else { throw Failure("the update information could not be read") }
        let manifest = UpdateManifest(version: version, build: build, dmg: dmg, size: size, sha256: sha.lowercased(),
                                      minimumSystemVersion: json["minimumSystemVersion"] as? String ?? "14.0",
                                      notes: json["notes"] as? String ?? "", signature: signature)
        func matches(_ text: String, _ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        guard matches(version, "^[0-9]+(\\.[0-9]+){1,3}$"), matches(build, "^[0-9]{1,14}$"),
              matches(dmg, "^Tessera-[0-9][0-9.]*\\.dmg$"), matches(manifest.sha256, "^[0-9a-f]{64}$"),
              size > 20_000_000, size < 8_000_000_000
        else { throw Failure("the update information is not in the expected form") }
        guard isSigned(manifest) else { throw Failure("the update information is not signed by Tessera's release key") }
        return manifest
    }

    /// The signature covers everything in the file: version, build, the disk image's name, size and SHA-256, the
    /// oldest macOS it runs on, and the notes (as their SHA-256).
    static func isSigned(_ m: UpdateManifest) -> Bool {
        guard let raw = Data(base64Encoded: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let signature = Data(base64Encoded: m.signature) else { return false }
        let notes = SHA256.hash(data: Data(m.notes.utf8)).map { String(format: "%02x", $0) }.joined()
        let text = "tessera-update 2\n\(m.version)\n\(m.build)\n\(m.dmg)\n\(m.size)\n\(m.sha256)\n\(m.minimumSystemVersion)\n\(notes)\n"
        return key.isValidSignature(signature, for: Data(text.utf8))
    }

    /// For curl: an https address is fetched over https only, also after redirects. (Test feeds are file:// or
    /// http://localhost.)
    static var httpsOnly: [String] { feed.hasPrefix("https://") ? ["--proto", "=https", "--proto-redir", "=https"] : [] }

    /// The newer release, or nil when this is the latest. Throws when the check itself fails.
    static func available() throws -> UpdateManifest? {
        let manifest = try fetchManifest()
        guard isNewer(manifest.version, than: currentVersion) else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let mac = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if isNewer(manifest.minimumSystemVersion, than: mac) {
            throw Failure("Tessera \(manifest.version) needs macOS \(manifest.minimumSystemVersion) or newer (this Mac has \(mac))")
        }
        return manifest
    }

    // MARK: - download

    static func downloadURL(for m: UpdateManifest) -> String {
        if let latest = feed.range(of: "/releases/latest/download/") {
            return feed[..<latest.lowerBound] + "/releases/download/\(m.version)/\(m.dmg)"
        }
        guard let slash = feed.lastIndex(of: "/") else { return m.dmg }
        return feed[...slash] + m.dmg
    }

    /// Downloads the release's disk image and checks its size and SHA-256 against the signed manifest.
    /// An update replaces the runtime a running game is using, so both steps refuse while one is open:
    /// the download (so nobody waits for 450 MB only to be told to close the game) and the swap itself.
    static func refuseWhileAGameRuns() throws {
        guard !gameIsRunning else { throw Failure("a Windows game is running. Close the game, then update") }
    }

    static func download(_ m: UpdateManifest, progress: ((Int64) -> Void)? = nil) throws -> URL {
        try refuseWhileAGameRuns()
        let fm = FileManager.default
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let done = downloads.appendingPathComponent(m.dmg), part = downloads.appendingPathComponent(m.dmg + ".part")
        func sizeOf(_ url: URL) -> Int64 { ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0 }
        if sizeOf(done) == m.size, sha256Hex(done) == m.sha256 { progress?(m.size); return done }   // from an earlier try
        try? fm.removeItem(at: done)
        try? fm.removeItem(at: part)
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-fsSL", "--retry", "2", "--connect-timeout", "20", "--max-time", "3600",
                          "--speed-limit", "20000", "--speed-time", "60"] + httpsOnly + ["-o", part.path, downloadURL(for: m)]
        curl.standardOutput = FileHandle.nullDevice
        curl.standardError = FileHandle.nullDevice
        do { try curl.run() } catch { throw Failure("the download could not start: \(error.localizedDescription)") }
        while curl.isRunning {
            Thread.sleep(forTimeInterval: 0.25)
            progress?(min(sizeOf(part), m.size))
        }
        guard curl.terminationStatus == 0 else {
            try? fm.removeItem(at: part)
            throw Failure([6, 7, 28, 35].contains(curl.terminationStatus) ? "the download stopped (no internet?)"
                                                                          : "the download failed (curl \(curl.terminationStatus))")
        }
        guard sizeOf(part) == m.size, sha256Hex(part) == m.sha256 else {
            try? fm.removeItem(at: part)
            throw Failure("the downloaded file is not the release Tessera's key signed (size or checksum differ)")
        }
        try fm.moveItem(at: part, to: done)
        progress?(m.size)
        return done
    }

    // MARK: - install

    /// A Windows game started through Tessera is running (its launcher process lives as long as the game).
    static var gameIsRunning: Bool {
        let support = Paths.support.path
        return run("/bin/ps", ["-axww", "-o", "args="]).output.split(whereSeparator: \.isNewline).contains { line in
            let command = line.trimmingCharacters(in: .whitespaces)
            return command.hasPrefix(support) && command.contains("/run waitforexitandrun ")
        }
    }

    /// Runs when Tessera opens: what an interrupted update left behind (a partial download, a half-copied new
    /// version next to the app) goes away. Not while an update is being installed.
    static func cleanUp() {
        let fm = FileManager.default
        let folder = Bundle.main.bundleURL.standardizedFileURL.deletingLastPathComponent()
        for name in [".Tessera-update.app", ".Tessera-previous.app"] {
            let leftover = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: leftover.path) { try? fm.removeItem(at: leftover) }
        }
        for item in (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasSuffix(".part") || item.lastPathComponent.hasPrefix("mount-") {
            try? fm.removeItem(at: item)
        }
    }

    private static func note(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile(); handle.write(Data("[\(stamp)] \(text)\n".utf8)); try? handle.close()
        } else {
            try? Data("[\(stamp)] \(text)\n".utf8).write(to: logFile)
        }
    }

    /// Copies the new Tessera.app out of the checked disk image, checks the copy, and starts the small script that
    /// swaps it in as soon as this Tessera has quit (a running app cannot replace itself). The caller quits right
    /// after. `relaunch` opens the new version when the swap is done.
    static func install(_ m: UpdateManifest, dmg: URL, relaunch: Bool) throws {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL.standardizedFileURL
        guard app.pathExtension == "app", !app.path.contains("/AppTranslocation/") else {
            throw Failure("Tessera has to be in your Applications folder to update itself")
        }
        try refuseWhileAGameRuns()
        let folder = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else {
            throw Failure("Tessera may not write to \(folder.path). Download the new version from the release page instead")
        }
        note("update \(currentVersion) (build \(currentBuild)) -> \(m.version) (build \(m.build)) from \(dmg.lastPathComponent)")

        let mount = downloads.appendingPathComponent("mount-\(getpid())")
        try? fm.removeItem(at: mount)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attached = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path], timeout: 180)
        guard attached.status == 0 else { throw Failure("the downloaded disk image could not be opened") }
        defer {
            run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60)
            try? fm.removeItem(at: mount)
        }
        let source = mount.appendingPathComponent("Tessera.app")
        guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              fm.fileExists(atPath: source.appendingPathComponent("Contents/MacOS/Tessera").path) else {
            throw Failure("the disk image does not hold Tessera.app")
        }
        let staged = folder.appendingPathComponent(".Tessera-update.app"), previous = folder.appendingPathComponent(".Tessera-previous.app")
        try? fm.removeItem(at: staged)
        let copied = run("/usr/bin/ditto", [source.path, staged.path], timeout: 900)
        guard copied.status == 0 else {
            try? fm.removeItem(at: staged)
            throw Failure("the new version could not be copied to \(folder.path): \(copied.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        // the copy is intact (its own code signature seals every file) and is the app and version the manifest names
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], timeout: 600).status == 0,
              info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == m.version else {
            try? fm.removeItem(at: staged)
            throw Failure("the new version did not pass its check after copying; nothing was changed")
        }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Where the file system can do it (APFS), the two bundles change places in ONE step: there is never a moment
        // without a Tessera.app, whatever interrupts the update. This Tessera keeps running from its own files, now
        // under the hidden name, until it quits a moment later; the script then removes them and opens the new one.
        // Elsewhere the script moves the old version away and the new one in after Tessera has quit, and puts the
        // old one back if the second move fails.
        var swapped = false
        if renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) == 0 {
            swapped = true
            note("the new version is in place (swapped in one step)")
        } else if errno != ENOTSUP && errno != EINVAL {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(at: staged)
            throw Failure("the new version could not be put in place (\(why)); nothing was changed")
        }

        let script = downloads.appendingPathComponent("swap.sh")
        let text = """
        #!/bin/sh
        # Tessera's update, the part after Tessera has quit.
        #   swapped: the new version is in place already; remove the previous one (it holds the place NEW had)
        #   move:    move the running version away, the new one in, and the old one back if that fails
        PID="$1"; APP="$2"; NEW="$3"; OLD="$4"; RELAUNCH="$5"; LOG="$6"; DMG="$7"; HOW="$8"
        exec >>"$LOG" 2>&1
        say() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
        n=0; while kill -0 "$PID" 2>/dev/null && [ $n -lt 300 ]; do sleep 0.2; n=$((n+1)); done
        if [ "$HOW" = swapped ]; then
            LEFT="$NEW"
        else
            if kill -0 "$PID" 2>/dev/null; then say "Tessera did not quit; the update was not installed"; rm -rf "$NEW"; exit 1; fi
            rm -rf "$OLD" 2>/dev/null
            if ! mv "$APP" "$OLD"; then
                say "the running version could not be moved away; the update was not installed"; rm -rf "$NEW"
                [ "$RELAUNCH" = 1 ] && open "$APP"; exit 1
            fi
            if ! mv "$NEW" "$APP"; then
                say "the new version could not be put in place; the previous one is back"; mv "$OLD" "$APP"
                [ "$RELAUNCH" = 1 ] && open "$APP"; exit 1
            fi
            LEFT="$OLD"
        fi
        rm -rf "$LEFT" 2>/dev/null
        [ -e "$LEFT" ] && mv "$LEFT" "$HOME/.Trash/Tessera (previous version $(date +%H%M%S)).app" 2>/dev/null
        rm -f "$DMG"
        say "installed"
        [ "$RELAUNCH" = 1 ] && open "$APP"
        exit 0
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        // the script runs in the background of a shell that ends at once, so it is nobody's child when Tessera quits
        swap.arguments = ["-c", "/bin/sh \"$0\" \"$@\" </dev/null >/dev/null 2>&1 &", script.path, "\(getpid())", app.path,
                          staged.path, previous.path, relaunch ? "1" : "0", logFile.path, dmg.path, swapped ? "swapped" : "move"]
        swap.standardOutput = FileHandle.nullDevice
        swap.standardError = FileHandle.nullDevice
        do { try swap.run() } catch {
            // after a swap the new version stays in place; what is left over goes when Tessera opens next (cleanUp)
            if !swapped { try? fm.removeItem(at: staged) }
            throw Failure("the update could not be finished: \(error.localizedDescription)")
        }
        swap.waitUntilExit()
        if !swapped { note("the new version is copied and checked; it goes into place when Tessera quits") }
    }
}
