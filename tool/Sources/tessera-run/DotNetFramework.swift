import Foundation

// MARK: - Microsoft .NET Framework 4.8 for the few games whose .NET launcher Wine Mono cannot run
//
// Wine runs .NET Framework programs on Wine Mono, which covers almost every game launcher. A few use parts it lacks:
// Assetto Corsa's launcher cannot load its CEF3 browser wrapper (Wine bug 58033, open upstream). For those games
// Microsoft's own .NET Framework 4.8 goes into that game's Windows folder - never into others - installed as winetricks
// installs it: Wine Mono's registration out, .NET 4.0 with Windows XP reported, then 4.8 with Windows 7 reported, and
// Microsoft's mscoree instead of Wine's. Wine registers mscoree again whenever a Windows folder is updated (a new
// Tessera); with Microsoft's mscoree in place that registration is Microsoft's and Wine Mono does not come back.
// It needs the player's go-ahead once (Microsoft's licence; about five minutes and 750 MB), and only then downloads
// Microsoft's installers (MicrosoftPackages.swift: dotNetFrameworkPackages, pinned SHA-256).
// A game's settings can ask for it (TESSERA_DOTNET=1, the app's ".NET Framework" switch) or refuse the automatic choice
// (TESSERA_DOTNET=0).

/// Launchers known to need it, by the file name Steam starts, and their game
let launchersNeedingDotNet = ["assettocorsa.exe": "Assetto Corsa"]

/// Written when .NET Framework 4.8 is in the Windows folder
func dotNetMarker(_ prefix: URL) -> URL { prefix.appendingPathComponent("drive_c/windows/tessera-dotnet48.txt") }

/// Why this program should get Microsoft's .NET Framework, or nil
func dotNetFrameworkReason(exe: String, env: [String: String]) -> String? {
    switch env["TESSERA_DOTNET"] {
    case "0": return nil
    case "1": return "this game's settings"
    default:
        return launchersNeedingDotNet[URL(fileURLWithPath: exe).lastPathComponent.lowercased()].map { "\($0)'s launcher" }
    }
}

/// Runs a program and returns what it printed (both streams)
func captureProcess(_ exe: URL, _ args: [String], env: [String: String]) -> String {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// The installed .NET Framework 4.x release number (528040 and up: 4.8), from the registry
func dotNetRelease(_ wine: URL, env: [String: String]) -> Int {
    let out = captureProcess(wine, ["reg", "query", #"HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full"#, "/v", "Release"], env: env)
    guard let r = out.range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression) else { return 0 }
    return Int(out[r].dropFirst(2), radix: 16) ?? 0
}

/// Shows a notification (not waited for)
func notifyPlayer(_ text: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(text)\" with title \"Tessera\""]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

/// Makes sure the Windows folder has .NET Framework 4.8, asking the player first. True when it has it afterwards.
@discardableResult
func ensureDotNetFramework(_ prefix: URL, env baseEnv: [String: String], reason: String) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: dotNetMarker(prefix).path) { return true }

    let ask = Process()
    ask.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    ask.arguments = ["-e", "display dialog \"\(reason.prefix(1).uppercased() + reason.dropFirst()) needs Microsoft .NET Framework 4.8, which Wine's .NET (Wine Mono) cannot stand in for. Install it into this game's Windows folder now?\\n\\nIt downloads 123 MB from Microsoft and takes about five minutes, once; other games are not affected. By installing you agree to Microsoft's .NET Framework licence terms.\" buttons {\"Not Now\", \"Install\"} default button \"Install\" with title \"Tessera\" with icon note"]
    let pipe = Pipe(); ask.standardOutput = pipe; ask.standardError = pipe
    try? ask.run(); ask.waitUntilExit()
    let answer = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard answer.contains("Install") else {
        log(".NET Framework 4.8 for \(reason): not now (the player's choice); Wine Mono runs the program")
        return false
    }

    for package in dotNetFrameworkPackages where !microsoftPackageIsDownloaded(package) {
        log(".NET Framework: downloading \(package.file) from Microsoft")
        if let failure = downloadMicrosoftPackage(package) {
            log(".NET Framework: \(failure)")
            notifyPlayer(".NET Framework could not be downloaded: \(failure)")
            return false
        }
    }
    notifyPlayer("Installing Microsoft .NET Framework 4.8 for this game - about five minutes, once.")
    let started = Date()

    var e = baseEnv
    e["WINEPREFIX"] = prefix.path
    e["WINEDEBUG"] = "-all"
    let base = "winemenubuilder.exe=d;winedbg.exe=d"
    e["WINEDLLOVERRIDES"] = base
    for key in ["TESSERA_BACKEND_DIR", "TESSERA_LIBVULKAN", "WINE_D3D_CONFIG"] { e.removeValue(forKey: key) }
    let wine = runtime.loader
    func reg(_ args: [String]) { runProcess(wine, ["reg"] + args + ["/f"], env: e) }

    // Wine Mono's registration out (winetricks: remove_mono): its uninstall entries, the .NET keys it wrote, and Wine's
    // mscoree stand-ins in the system folders (Microsoft's installers would not replace them)
    for line in captureProcess(wine, ["uninstaller", "--list"], env: e).split(separator: "\n") where line.contains("Wine Mono") {
        if let id = line.split(separator: "|").first {
            log(".NET Framework: removing \(line.split(separator: "|").last ?? "Wine Mono")")
            runProcess(wine, ["uninstaller", "--remove", String(id)], env: e)
        }
    }
    runProcess(wine, ["reg", "delete", #"HKLM\Software\Microsoft\NET Framework Setup\NDP\v3.5"#, "/f"], env: e)
    runProcess(wine, ["reg", "delete", #"HKLM\Software\Microsoft\NET Framework Setup\NDP\v4"#, "/f"], env: e)
    for dir in ["system32", "syswow64"] {
        let dll = prefix.appendingPathComponent("drive_c/windows/\(dir)/mscoree.dll")
        if let data = try? Data(contentsOf: dll, options: .mappedIfSafe), data.range(of: Data("WINE_MONO_OVERRIDES".utf8)) != nil {
            try? fm.removeItem(at: dll)
        }
    }

    // Windows version the folder reports now, restored at the end
    let winver = captureProcess(wine, ["winecfg", "/v"], env: e).split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty && !$0.contains(" ") } ?? "win10"

    var install = e
    install["WINEDLLOVERRIDES"] = base + ";fusion=b"
    runProcess(wine, ["winecfg", "/v", "winxp"], env: e)
    let installer40 = redistCache.appendingPathComponent("dotNetFx40_Full_x86_x64.exe").path
    let status40 = runProcess(wine, [installer40, "/q", "/c:install.exe /q"], env: install, cwd: redistCache)
    reg(["add", #"HKCU\Software\Wine\DllOverrides"#, "/v", "mscoree", "/d", "native"])
    reg(["add", #"HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full"#, "/v", "Install", "/t", "REG_DWORD", "/d", "1"])
    reg(["add", #"HKLM\Software\Microsoft\NET Framework Setup\NDP\v4\Full"#, "/v", "Version", "/t", "REG_SZ", "/d", "4.0.30319"])
    // programs made for .NET 2.0-3.5 run on 4.8 instead of stopping at ".NET: This application could not be started"
    // (Wine bug 41727), in both registry views. The 32-bit one is Wow6432Node\Microsoft\.NETFramework: winetricks
    // writes Wow6432Node\.NETFramework, which no program reads, and then Wine's registration of its 32-bit DLLs at
    // every update of the Windows folder (a new Tessera) stopped at that question until someone answered it.
    reg(["add", #"HKLM\Software\Microsoft\.NETFramework"#, "/v", "OnlyUseLatestCLR", "/t", "REG_DWORD", "/d", "1"])
    reg(["add", #"HKLM\Software\Wow6432Node\Microsoft\.NETFramework"#, "/v", "OnlyUseLatestCLR", "/t", "REG_DWORD", "/d", "1"])

    runProcess(wine, ["winecfg", "/v", "win7"], env: e)
    install["WINEDLLOVERRIDES"] = base + ";fusion=b;mscoree=n"
    let installer48 = redistCache.appendingPathComponent("ndp48-x86-x64-allos-enu.exe").path
    let status48 = runProcess(wine, [installer48, "/sfxlang:1027", "/q", "/norestart"], env: install, cwd: redistCache)
    runProcess(wine, ["winecfg", "/v", winver], env: e)

    let release = dotNetRelease(wine, env: e)
    let minutes = Int(Date().timeIntervalSince(started) / 60 + 0.5)
    guard release >= 528040 else {
        log(".NET Framework 4.8: the installers ended with \(status40) and \(status48), but the folder reports release \(release); not marked installed")
        notifyPlayer("Microsoft .NET Framework could not be installed; the game log has the details.")
        return false
    }
    try? "Microsoft .NET Framework 4.8 (release \(release)), installed by Tessera for \(reason)\n"
        .write(to: dotNetMarker(prefix), atomically: true, encoding: .utf8)
    log(".NET Framework 4.8 installed in \(minutes) min (release \(release), installers \(status40)/\(status48), Windows version back to \(winver))")
    notifyPlayer("Microsoft .NET Framework 4.8 is installed; the game starts now.")
    return true
}
