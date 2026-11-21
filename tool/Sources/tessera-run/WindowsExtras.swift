import Foundation

// MARK: - Windows extras
//
// What a Windows PC has that Wine does not, put into every Windows folder once:
//   * OpenAL Soft (OpenAL32.dll, open source, carried in the runtime: lib/tessera-redist)
//   * Microsoft's Visual C++ runtimes 2005-2022 (with MFC 10-14), MFC 4.2, the DirectX June 2010 parts Wine lacks
//     (XACT 2.1-2.10 versions Wine does not implement, D3DCSX) and the Visual Basic 6 runtime (msvbvm60.dll).
//     Microsoft's licence does not let Tessera ship these, so they are downloaded from Microsoft on this Mac - once,
//     checked against pinned SHA-256, as winetricks does. Wine's own versions stay as the fallback
//     (DLL overrides "n,b" in main.swift).
// New Windows folders get all of it through the template (it is installed there once per runtime); folders made
// earlier get it at their next start. Without a network the Microsoft part is skipped and tried again next start.

/// Bump when the set or the way it is installed changes: every Windows folder then installs again (a folder that
/// has an earlier set gets only what was added since, see installWindowsExtras).
/// 1: Tessera 1.2.9. 2: + the Visual Basic 6 runtime.
let windowsExtrasVersion = "2"

// The packages themselves (URLs, checksums, sizes) and their download: MicrosoftPackages.swift, shared with the app.


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

/// The app downloads the packages as soon as it opens; this is the fallback for a game started before the app ever
/// was (or while it was offline). True when every package is there and matches its checksum.
func downloadMicrosoftPackages() -> Bool {
    var complete = true
    for package in microsoftPackages where !microsoftPackageIsDownloaded(package) {
        log("Windows extras: \(package.file) is not downloaded yet; downloading it from Microsoft now")
        if let failure = downloadMicrosoftPackage(package) {
            log("Windows extras: could not download \(package.file): \(failure)")
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
    var installed = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
    // The mark alone is not enough: up to 1.2.11 it was written even when every installer had failed (on macOS before
    // 27 they all stopped at start), and such a folder never got Microsoft's runtimes. So Microsoft's files are looked
    // for as well; a folder where they did not install is tried again once per Tessera runtime, not at every start.
    let failedMark = prefix.appendingPathComponent(".tessera-windows-extras-failed")
    if installed == windowsExtrasVersion, microsoftRuntimesPresent(prefix) { return }
    if (try? String(contentsOf: failedMark, encoding: .utf8)) == runtimeStamp() { return }
    if !installed.isEmpty, !microsoftRuntimesPresent(prefix) {
        log("Windows extras: marked as installed, but Microsoft's runtimes are not there (set up by an earlier Tessera whose installers failed); installing them now")
        installed = ""
    }
    let started = Date()
    let windows = prefix.appendingPathComponent("drive_c/windows")
    // Windows' names: system32 holds the 64-bit DLLs, syswow64 the 32-bit ones
    let dir64 = windows.appendingPathComponent("system32"), dir32 = windows.appendingPathComponent("syswow64")
    guard fm.fileExists(atPath: dir64.path) else { return }
    // a folder with set 1 (Tessera 1.2.9) has everything but the Visual Basic 6 runtime: add only that (a file copy)
    if installed == "1" {
        guard downloadMicrosoftPackages() else {
            log("Windows extras: the Visual Basic 6 runtime is not downloaded yet (offline?); it follows at a later start")
            return
        }
        installVisualBasic6(dir32)
        try? windowsExtrasVersion.write(to: marker, atomically: true, encoding: .utf8)
        log("Windows extras: Visual Basic 6 runtime added")
        return
    }
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

    log("Windows extras: Microsoft Visual C++ 2005-2022 (with MFC), MFC 4.2, DirectX 2010 parts, Visual Basic 6, OpenAL (once per Windows folder)")
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
    installVisualBasic6(dir32)

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

    if microsoftRuntimesPresent(prefix) {
        try? windowsExtrasVersion.write(to: marker, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: failedMark)
        log("Windows extras installed in \(Int(Date().timeIntervalSince(started))) s")
    } else {
        try? runtimeStamp().write(to: failedMark, atomically: true, encoding: .utf8)
        log("Windows extras: Microsoft's runtimes did not install (the lines above name the installers that failed); Wine's own versions are used, and Tessera tries again after its next update")
    }
}

/// True when Microsoft's Visual C++ 2015-2022 package really is in the Windows folder: its MFC library is a file only
/// that package brings (Wine has no version of it), and it is the last of the Visual C++ packages to be installed.
func microsoftRuntimesPresent(_ prefix: URL) -> Bool {
    FileManager.default.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/system32/mfc140.dll").path)
}

/// Names this runtime build (its wine.inf's time and size, which change with every runtime)
func runtimeStamp() -> String {
    let inf = runtime.root.appendingPathComponent("share/wine/wine.inf").path
    let attrs = try? FileManager.default.attributesOfItem(atPath: inf)
    return "\(Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)) \(attrs?[.size] ?? 0)"
}

/// The Visual Basic 6 runtime (32-bit; Windows keeps it in SysWOW64), from the cache (MicrosoftPackages.swift). A real
/// one already in the folder stays; Wine has no version of its own.
func installVisualBasic6(_ dir32: URL) {
    let fm = FileManager.default
    let source = redistCache.appendingPathComponent("msvbvm60.dll")
    let present = ((try? fm.contentsOfDirectory(atPath: dir32.path)) ?? []).contains { $0.lowercased() == "msvbvm60.dll" }
    if !present, fm.fileExists(atPath: source.path) {
        try? fm.copyItem(at: source, to: dir32.appendingPathComponent("msvbvm60.dll"))
    }
}
