import CryptoKit
import Foundation

// MARK: - Windows extras
//
// What a Windows PC has that Wine does not, put into every Windows folder once:
//   * OpenAL Soft (OpenAL32.dll, open source, carried in the runtime: lib/tessera-redist)
//   * Microsoft's Visual C++ runtimes 2005-2022 (with MFC 10-14), MFC 4.2 and the DirectX June 2010 parts Wine lacks
//     (XACT 2.1-2.10 versions Wine does not implement, D3DCSX). Microsoft's licence does not let Tessera ship these,
//     so they are downloaded from Microsoft on this Mac - once, checked against pinned SHA-256 - like CrossOver and
//     winetricks do. Wine's own versions stay as the fallback (DLL overrides "n,b" in main.swift).
// New Windows folders get all of it through the template (it is installed there once per runtime); folders made
// earlier get it at their next start. Without a network the Microsoft part is skipped and tried again next start.

/// Bump when the set or the way it is installed changes: every Windows folder then installs again.
let windowsExtrasVersion = "1"

struct MicrosoftPackage { let file: String; let url: String; let sha256: String }

// URLs and checksums as winetricks (20260125) pins them; the 2015-2022 ones are Microsoft's fixed per-version
// addresses behind aka.ms/vs/17/release (Visual C++ 14.44).
let microsoftPackages: [MicrosoftPackage] = [
    .init(file: "vcredist_2005_x86.exe", url: "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE",
          sha256: "8648c5fc29c44b9112fe52f9a33f80e7fc42d10f3b5b42b2121542a13e44adfd"),
    .init(file: "vcredist_2005_x64.exe", url: "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE",
          sha256: "4487570bd86e2e1aac29db2a1d0a91eb63361fcaac570808eb327cd4e0e2240d"),
    .init(file: "vcredist_2008_x86.exe", url: "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe",
          sha256: "8742bcbf24ef328a72d2a27b693cc7071e38d3bb4b9b44dec42aa3d2c8d61d92"),
    .init(file: "vcredist_2008_x64.exe", url: "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe",
          sha256: "c5e273a4a16ab4d5471e91c7477719a2f45ddadb76c7f98a38fa5074a6838654"),
    .init(file: "vcredist_2010_x86.exe", url: "https://download.microsoft.com/download/5/B/C/5BC5DBB3-652D-4DCE-B14A-475AB85EEF6E/vcredist_x86.exe",
          sha256: "31d32fa39d52cac9a765a43660431f7a127eee784b54b2f5e2af3e2b763a1af8"),
    .init(file: "vcredist_2010_x64.exe", url: "https://download.microsoft.com/download/A/8/0/A80747C3-41BD-45DF-B505-E9710D2744E0/vcredist_x64.exe",
          sha256: "2fddbc3aaaab784c16bc673c3bae5f80929d5b372810dbc28649283566d33255"),
    .init(file: "vcredist_2012_x86.exe", url: "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe",
          sha256: "b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386"),
    .init(file: "vcredist_2012_x64.exe", url: "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe",
          sha256: "681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064"),
    .init(file: "vcredist_2013_x86.exe", url: "https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x86.exe",
          sha256: "89f4e593ea5541d1c53f983923124f9fd061a1c0c967339109e375c661573c17"),
    .init(file: "vcredist_2013_x64.exe", url: "https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x64.exe",
          sha256: "20e2645b7cd5873b1fa3462b99a665ac8d6e14aae83ded9d875fea35ffdd7d7e"),
    .init(file: "VC_redist_2022.x86.exe", url: "https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe",
          sha256: "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64"),
    .init(file: "VC_redist_2022.x64.exe", url: "https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe",
          sha256: "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b"),
    .init(file: "VC6RedistSetup_deu.exe", url: "https://download.microsoft.com/download/vc60pro/Update/2/W9XNT4/EN-US/VC6RedistSetup_deu.exe",
          sha256: "c2eb91d9c4448d50e46a32fecbcc3b418706d002beab9b5f4981de552098cee7"),
    .init(file: "directx_Jun2010_redist.exe", url: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
          sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"),
]

/// Visual C++ installers in order, their quiet switches, and the DLLs of that version Wine puts into a Windows folder
/// as stand-ins: those are removed first (only Wine's own, never a real one), or the installer may keep them because
/// their version number looks newer (msvcr120); one still missing afterwards gets Wine's stand-in back.
let visualCppInstallers: [(file: String, args: [String], standIns: [String])] = [
    ("vcredist_2005_x86.exe", ["/q"], []),
    ("vcredist_2005_x64.exe", ["/q"], []),
    ("vcredist_2008_x86.exe", ["/q"], []),
    ("vcredist_2008_x64.exe", ["/q"], []),
    ("vcredist_2010_x86.exe", ["/q", "/norestart"], ["msvcp100", "msvcr100", "vcomp100", "atl100"]),
    ("vcredist_2010_x64.exe", ["/q", "/norestart"], ["msvcp100", "msvcr100", "vcomp100", "atl100"]),
    ("vcredist_2012_x86.exe", ["/install", "/quiet", "/norestart"], ["msvcp110", "msvcr110", "vcomp110", "atl110"]),
    ("vcredist_2012_x64.exe", ["/install", "/quiet", "/norestart"], ["msvcp110", "msvcr110", "vcomp110", "atl110"]),
    ("vcredist_2013_x86.exe", ["/install", "/quiet", "/norestart"], ["msvcp120", "msvcr120", "vcomp120"]),
    ("vcredist_2013_x64.exe", ["/install", "/quiet", "/norestart"], ["msvcp120", "msvcr120", "vcomp120"]),
    ("VC_redist_2022.x86.exe", ["/install", "/quiet", "/norestart"],
     ["msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcruntime140", "concrt140", "vcomp140"]),
    ("VC_redist_2022.x64.exe", ["/install", "/quiet", "/norestart"],
     ["msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcruntime140", "vcruntime140_1",
      "concrt140", "vcomp140"]),
]

/// DirectX June 2010 parts Wine has no version of: 32-bit XACT engines (64-bit XACT from this package misbehaves under
/// Wine - winetricks' finding) and D3DCSX for both. XACT engines are COM servers and get registered.
let directXExtras32 = ["xactengine2_1.dll", "xactengine2_2.dll", "xactengine2_3.dll", "xactengine2_5.dll", "xactengine2_6.dll",
                       "xactengine2_8.dll", "xactengine2_10.dll", "d3dcsx_42.dll", "d3dcsx_43.dll"]
let directXExtras64 = ["d3dcsx_42.dll", "d3dcsx_43.dll"]

let redistCache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Tessera/redist")

func sha256Hex(_ file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Downloads what is not in the cache yet; true when every package is there and matches its checksum.
func downloadMicrosoftPackages() -> Bool {
    let fm = FileManager.default
    try? fm.createDirectory(at: redistCache, withIntermediateDirectories: true)
    var complete = true
    for package in microsoftPackages {
        let file = redistCache.appendingPathComponent(package.file)
        if fm.fileExists(atPath: file.path), sha256Hex(file) == package.sha256 { continue }
        let part = redistCache.appendingPathComponent(package.file + ".part-\(getpid())")
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-fsSL", "--retry", "2", "--connect-timeout", "20", "--max-time", "1200", "-o", part.path, package.url]
        curl.standardOutput = logHandle
        curl.standardError = logHandle
        if (try? curl.run()) != nil { curl.waitUntilExit() }
        if curl.terminationStatus == 0, sha256Hex(part) == package.sha256 {
            try? fm.removeItem(at: file)
            try? fm.moveItem(at: part, to: file)
        } else {
            try? fm.removeItem(at: part)
            log("Windows extras: could not download \(package.file) from Microsoft\(curl.terminationStatus == 0 ? " (checksum differs)" : "")")
            complete = false
        }
    }
    return complete
}

/// Wine's stand-in DLLs carry this text; real DLLs never do.
func isWineStandIn(_ file: URL) -> Bool {
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
    return data.range(of: Data("Wine builtin DLL".utf8)) != nil
}

/// waitForServer: let wineserver end and write the registry (the template, which is moved right after); a game's own
/// folder may have a session running that must not be waited for.
func installWindowsExtras(_ prefix: URL, env baseEnv: [String: String], waitForServer: Bool) {
    let fm = FileManager.default
    let marker = prefix.appendingPathComponent(".tessera-windows-extras")
    if (try? String(contentsOf: marker, encoding: .utf8)) == windowsExtrasVersion { return }
    let started = Date()
    let windows = prefix.appendingPathComponent("drive_c/windows")
    // Windows' names: system32 holds the 64-bit DLLs, syswow64 the 32-bit ones
    let dir64 = windows.appendingPathComponent("system32"), dir32 = windows.appendingPathComponent("syswow64")
    guard fm.fileExists(atPath: dir64.path) else { return }
    var e = baseEnv
    e["WINEPREFIX"] = prefix.path
    e["WINEDEBUG"] = "-all"
    e["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d;winedbg.exe=d"
    for key in ["TESSERA_BACKEND_DIR", "TESSERA_LIBVULKAN", "WINE_D3D_CONFIG"] { e.removeValue(forKey: key) }

    // OpenAL Soft where Creative's installer would put OpenAL32.dll (a real one already there stays)
    for (arch, dir) in [("x86_64", dir64), ("i386", dir32)] {
        let source = runtime.root.appendingPathComponent("lib/tessera-redist/\(arch)/OpenAL32.dll")
        let present = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.lowercased() == "openal32.dll" }
        if !present, fm.fileExists(atPath: source.path) {
            try? fm.copyItem(at: source, to: dir.appendingPathComponent("OpenAL32.dll"))
        }
    }

    log("Windows extras: Microsoft Visual C++ 2005-2022 (with MFC), MFC 4.2, DirectX 2010 parts, OpenAL (once per Windows folder)")
    guard downloadMicrosoftPackages() else {
        log("Windows extras: Microsoft's runtimes are not complete (offline?); OpenAL is in, the rest follows at a later start")
        return
    }
    let wine = runtime.loader
    let tool = { (path: String) in windowsPath(forUnix: path) }

    for installer in visualCppInstallers {
        let is64 = installer.file.contains("x64")
        let dir = is64 ? dir64 : dir32
        let arch = is64 ? "x86_64-windows" : "i386-windows"
        for name in installer.standIns {
            let file = dir.appendingPathComponent(name + ".dll")
            if fm.fileExists(atPath: file.path), isWineStandIn(file) { try? fm.removeItem(at: file) }
        }
        let status = runProcess(wine, [tool(redistCache.appendingPathComponent(installer.file).path)] + installer.args, env: e)
        if status != 0 { log("Windows extras: \(installer.file) ended with \(status)") }
        for name in installer.standIns {
            let file = dir.appendingPathComponent(name + ".dll")
            let wineCopy = runtime.root.appendingPathComponent("lib/wine/\(arch)/\(name).dll")
            if !fm.fileExists(atPath: file.path), fm.fileExists(atPath: wineCopy.path) { try? fm.copyItem(at: wineCopy, to: file) }
        }
    }

    // MFC 4.2 (part of every Windows, 32-bit): from Microsoft's Visual C++ 6 package, two self-extracting layers
    let temp = windows.appendingPathComponent("temp/tessera-extras")
    try? fm.removeItem(at: temp)
    try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
    let vc6 = temp.appendingPathComponent("vc6"), vc6files = temp.appendingPathComponent("vc6files")
    runProcess(wine, [tool(redistCache.appendingPathComponent("VC6RedistSetup_deu.exe").path), "/T:\(tool(vc6.path))", "/C", "/Q"], env: e)
    if let inner = ((try? fm.contentsOfDirectory(atPath: vc6.path)) ?? []).first(where: { $0.lowercased() == "vcredist.exe" }) {
        runProcess(wine, [tool(vc6.appendingPathComponent(inner).path), "/T:\(tool(vc6files.path))", "/C", "/Q"], env: e)
    }
    for item in (try? fm.contentsOfDirectory(atPath: vc6files.path)) ?? []
    where ["mfc42.dll", "mfc42u.dll"].contains(item.lowercased()) {
        let target = dir32.appendingPathComponent(item.lowercased())
        if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: vc6files.appendingPathComponent(item), to: target) }
    }

    // DirectX June 2010: its cabinets, then the few DLLs Wine has no version of
    let dx = temp.appendingPathComponent("dx"), dxFiles = temp.appendingPathComponent("dxfiles")
    runProcess(wine, [tool(redistCache.appendingPathComponent("directx_Jun2010_redist.exe").path), "/Q", "/T:\(tool(dx.path))"], env: e)
    try? fm.createDirectory(at: dxFiles.appendingPathComponent("x86"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: dxFiles.appendingPathComponent("x64"), withIntermediateDirectories: true)
    for cab in (try? fm.contentsOfDirectory(atPath: dx.path)) ?? [] {
        let lower = cab.lowercased()
        guard lower.hasSuffix(".cab"), lower.contains("_xact_") || lower.contains("_d3dcsx_") else { continue }
        let into = dxFiles.appendingPathComponent(lower.contains("_x64") ? "x64" : "x86")
        runProcess(wine, ["extrac32", "/Y", "/E", "/L", tool(into.path), tool(dx.appendingPathComponent(cab).path)], env: e)
    }
    var registered: [String] = []
    for (names, from, to) in [(directXExtras32, "x86", dir32), (directXExtras64, "x64", dir64)] {
        let found = (try? fm.contentsOfDirectory(atPath: dxFiles.appendingPathComponent(from).path)) ?? []
        for name in names {
            guard let match = found.first(where: { $0.lowercased() == name }) else { continue }
            let target = to.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { continue }
            try? fm.copyItem(at: dxFiles.appendingPathComponent(from).appendingPathComponent(match), to: target)
            if name.hasPrefix("xactengine") { registered.append(name) }
        }
    }
    if !registered.isEmpty {
        runProcess(wine, [tool(dir32.appendingPathComponent("regsvr32.exe").path), "/s"] + registered, env: e)
    }
    try? fm.removeItem(at: temp)
    if waitForServer { runProcess(runtime.server, ["-w"], env: e) }   // the registry is written when wineserver ends

    try? windowsExtrasVersion.write(to: marker, atomically: true, encoding: .utf8)
    log("Windows extras installed in \(Int(Date().timeIntervalSince(started))) s")
}
