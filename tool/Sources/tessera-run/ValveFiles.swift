import Foundation

// MARK: - Valve's Steam files for Windows games
//
// A Windows game reaches Steam through steamclient.dll / steamclient64.dll in a Steam folder, some games first check
// that those files and steam.exe carry Valve's signature, and Steam's first-start scripts are run by Valve's
// iscriptevaluator.exe. The Linux Steam client ships these Windows files for Proton (its "legacycompat" folder).
// The Mac client does not: on a Mac that folder holds nothing but the script Steam wants to run.
//
// Up to 1.2.11 Tessera took the files from Steam's legacycompat folder without checking who had put them there. On
// the Mac Tessera was made on, another tool had; on every other Mac they were missing, so Steam's first-start step
// failed at every start ("exited with 1") and games met only Tessera's stand-in for Steam's client library.
//
// Tessera now fetches Valve's own files from Valve's update server - the package of the Linux client that holds
// them - checks the package against its SHA-256 and keeps the six files in its own folder. The game launcher puts
// copies into each game's Windows folder and into Steam's legacycompat folder, where Steam and its script runner look
// for them (the runner starts "legacycompat\SteamService.exe" from Steam's folder); "Remove from Steam" takes those
// out again. The files are Valve's, unmodified, and not part of Tessera.
//
// One file, used by both programs (the app links to it), like MicrosoftPackages.swift: the app downloads them as soon
// as it opens; the game launcher only when the app has not.

/// Where Tessera keeps them (one copy for every Windows folder)
let valveFilesFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Tessera/valve/legacycompat")

/// The files, and where each lies in Valve's package
let valveFiles: [(name: String, inPackage: String)] = [
    ("steamclient.dll", "steamclient.dll"),
    ("steamclient64.dll", "steamclient64.dll"),
    ("GameOverlayRenderer64.dll", "GameOverlayRenderer64.dll"),
    ("Steam.dll", "legacycompat/Steam.dll"),
    ("SteamService.exe", "legacycompat/SteamService.exe"),
    ("iscriptevaluator.exe", "legacycompat/iscriptevaluator.exe"),
]

struct ValvePackage { let file: String; let size: Int64; let sha256: String }

let valveUpdateServer = "https://client-update.steamstatic.com/"
/// Valve's list of the Linux client's packages; the entry below names the package with the Windows files
let valvePackageList = "steam_client_ubuntu12"
let valvePackageName = "bins_misc_ubuntu12"
/// The package of Steam client 1792618285 (November 2026), the one Tessera was tested with. Valve's server keeps
/// earlier packages for a while; once this one is gone, the current one is taken from Valve's package list, which
/// gives its size and SHA-256.
let valvePinnedPackage = ValvePackage(file: "bins_misc_ubuntu12.zip.f8ced8ce928c1195f7176b442c2a8f8a731d3a2a",
                                      size: 29_388_966,
                                      sha256: "81cead844fbd7bc88ad089d26503fd6871c298d89e26a38bf90cacf855ff66e4")
/// What the download moves over the network
let valveDownloadSize = valvePinnedPackage.size

/// True when every file is in the folder `dir`.
func valveFilesAreIn(_ dir: URL) -> Bool {
    valveFiles.allSatisfy { file in
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(file.name).path))?[.size] as? NSNumber
        return (size?.int64Value ?? 0) > 0
    }
}

/// True when Tessera has downloaded them.
func valveFilesAreDownloaded() -> Bool { valveFilesAreIn(valveFilesFolder) }

/// The package Valve's server offers now, from Valve's package list.
private func currentValvePackage() -> ValvePackage? {
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-fsSL", "--retry", "2", "--connect-timeout", "20", "--max-time", "60", valveUpdateServer + valvePackageList]
    let pipe = Pipe()
    curl.standardOutput = pipe
    curl.standardError = FileHandle.nullDevice
    guard (try? curl.run()) != nil else { return nil }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    curl.waitUntilExit()
    guard curl.terminationStatus == 0, let start = text.range(of: "\"\(valvePackageName)\""),
          let end = text.range(of: "}", range: start.upperBound..<text.endIndex) else { return nil }
    let block = String(text[start.upperBound..<end.lowerBound])
    func value(_ key: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s+\"([^\"]+)\""),
              let m = re.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let r = Range(m.range(at: 1), in: block) else { return nil }
        return String(block[r])
    }
    guard let file = value("file"), let size = value("size").flatMap({ Int64($0) }), let sha = value("sha2"),
          file.hasPrefix(valvePackageName + ".zip."), !file.contains("/"), sha.count == 64 else { return nil }
    return ValvePackage(file: file, size: size, sha256: sha.lowercased())
}

/// Downloads one package to `to`; nil when it arrived and matches its checksum, else (reason, the server answered
/// that the file is not there).
private func fetchValvePackage(_ package: ValvePackage, to part: URL, maxTime: Int, progress: ((Int64) -> Void)?) -> (reason: String, gone: Bool)? {
    let fm = FileManager.default
    try? fm.removeItem(at: part)
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    // gives up on a connection that stalls (under 20 KB/s for 30 s): a game is waiting to start
    curl.arguments = ["-fsSL", "--retry", "2", "--connect-timeout", "20", "--max-time", "\(maxTime)",
                      "--speed-limit", "20000", "--speed-time", "30", "-o", part.path, valveUpdateServer + package.file]
    curl.standardOutput = FileHandle.nullDevice
    curl.standardError = FileHandle.nullDevice
    do { try curl.run() } catch { return ("could not start curl: \(error.localizedDescription)", false) }
    while curl.isRunning {
        Thread.sleep(forTimeInterval: 0.25)
        progress?(((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0)
    }
    guard curl.terminationStatus == 0 else {
        try? fm.removeItem(at: part)
        let unreachable = [6, 7, 28, 35].contains(curl.terminationStatus)
        return (unreachable ? "Valve's server could not be reached (no internet?)"
                            : "the download of Valve's Steam files failed (curl \(curl.terminationStatus))",
                curl.terminationStatus == 22)      // 22: an HTTP error such as 404
    }
    guard sha256Hex(part) == package.sha256 else {
        try? fm.removeItem(at: part)
        return ("Valve's package did not match its checksum", false)
    }
    return nil
}

/// Downloads Valve's files into Tessera's folder; they only land there when the package matched its checksum and
/// every file came out of it. `progress` gets the bytes received so far. Returns nil on success, else the reason.
func downloadValveFiles(maxTime: Int = 900, progress: ((Int64) -> Void)? = nil) -> String? {
    let fm = FileManager.default
    let parent = valveFilesFolder.deletingLastPathComponent()
    do { try fm.createDirectory(at: parent, withIntermediateDirectories: true) } catch {
        return "could not make Tessera's folder for Valve's files: \(error.localizedDescription)"
    }
    let part = parent.appendingPathComponent("package.zip.part-\(getpid())")
    let work = parent.appendingPathComponent("unpack-\(getpid())")
    defer { try? fm.removeItem(at: part); try? fm.removeItem(at: work) }

    var source = valvePinnedPackage
    if let failure = fetchValvePackage(source, to: part, maxTime: maxTime, progress: progress) {
        // not on the server any more: take the package Valve offers today
        guard failure.gone, let current = currentValvePackage(), current.file != source.file else { return failure.reason }
        source = current
        if let second = fetchValvePackage(source, to: part, maxTime: maxTime, progress: progress) { return second.reason }
    }
    progress?(source.size)

    try? fm.removeItem(at: work)
    do { try fm.createDirectory(at: work, withIntermediateDirectories: true) } catch {
        return "could not unpack Valve's files: \(error.localizedDescription)"
    }
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    // -j: without the package's folders; only the six files are taken out of it
    unzip.arguments = ["-o", "-j", "-qq", part.path] + valveFiles.map(\.inPackage) + ["-d", work.path]
    unzip.standardOutput = FileHandle.nullDevice
    unzip.standardError = FileHandle.nullDevice
    do { try unzip.run() } catch { return "could not start unzip: \(error.localizedDescription)" }
    unzip.waitUntilExit()
    guard unzip.terminationStatus == 0, valveFilesAreIn(work) else {
        return "Valve's package does not hold the expected files (unzip \(unzip.terminationStatus))"
    }
    try? source.file.write(to: work.appendingPathComponent("from-package.txt"), atomically: true, encoding: .utf8)
    try? fm.removeItem(at: valveFilesFolder)
    do { try fm.moveItem(at: work, to: valveFilesFolder) } catch {
        return "could not keep Valve's files: \(error.localizedDescription)"
    }
    return nil
}
