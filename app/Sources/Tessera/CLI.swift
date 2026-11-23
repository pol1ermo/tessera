import Foundation

/// The app's binary also works from Terminal, for scripts and testing:
///
///     Tessera.app/Contents/MacOS/Tessera --status
///     Tessera.app/Contents/MacOS/Tessera --install [--all-games] [--keep-mappings]
///     Tessera.app/Contents/MacOS/Tessera --uninstall
///     Tessera.app/Contents/MacOS/Tessera --restore-steam                    (Valve's own files back into Steam.app)
///     Tessera.app/Contents/MacOS/Tessera --play-windows-version APPID
///     Tessera.app/Contents/MacOS/Tessera --launch-entries APPID... [--file appinfo.vdf]   (what Steam can start)
///     Tessera.app/Contents/MacOS/Tessera --runtimes | --download-runtimes   (Microsoft's runtimes)
///     Tessera.app/Contents/MacOS/Tessera --check-update | --update [--reopen]  (a newer Tessera; Updater.swift)
///
/// TESSERA_STEAM_APP=/path/to/Steam.app points every step at another copy of Steam.app.
enum CLI {
    static let commands = ["--status", "--install", "--uninstall", "--restore-steam", "--play-windows-version", "--launch-entries", "--runtimes", "--download-runtimes", "--check-update", "--update", "--help"]

    /// Runs a command and exits when the app was started with one; returns otherwise.
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first, commands.contains(command) else { return }
        do {
            switch command {
            case "--status":
                print("Steam.app: \(Paths.steamApp.path)")
                print("state: \(describe(SteamSetup.state()))")
                for game in GameLibrary.windowsGames() { print("  \(game.id)\t\(game.name)") }
                let stuck = GameLibrary.macVersionsThatCannotRun()
                if !stuck.isEmpty { print("Mac versions that cannot run:") }
                for game in stuck { print("  \(game.id)\t\(game.name)\t(\(game.macProblem?.short ?? "?"))") }
            case "--install":
                try SteamSetup.install(useForAllWindowsGames: args.contains("--all-games"),
                                       setDefaultTool: !args.contains("--keep-mappings"))
                print("state: \(describe(SteamSetup.state()))")
            case "--play-windows-version":
                guard args.count > 1, Int(args[1]) != nil else { throw SteamSetup.SetupError.failed("usage: --play-windows-version APPID") }
                try SteamSetup.playWindowsVersion(appID: args[1])
                print("\(args[1]) now plays its Windows version through Tessera; open Steam and press Update (or Play) on the game to download it")
            case "--launch-entries":
                // Steam's own launch entries of the given apps (appcache/appinfo.vdf): why a game is, or is not,
                // listed under "Mac versions that can't run"
                var file = AppInfo.file
                var ids: [String] = []
                var i = 1
                while i < args.count {
                    if args[i] == "--file", i + 1 < args.count { file = URL(fileURLWithPath: args[i + 1]); i += 2 }
                    else { ids.append(args[i]); i += 1 }
                }
                let found = AppInfo.launchEntries(of: Set(ids), in: file)
                for id in ids {
                    guard let entries = found[id] else { print("\(id): not in \(file.lastPathComponent)"); continue }
                    print("\(id): \(entries.count) launch entries, \(entries.contains(where: \.startsOnMac) ? "one starts on a Mac" : "none starts on a Mac")")
                    for e in entries { print("  \(e.executable)\t\(e.oslist.isEmpty ? "(every system)" : e.oslist)") }
                }
            case "--runtimes":
                for package in microsoftPackages {
                    print("\(microsoftPackageIsDownloaded(package) ? "downloaded" : "missing   ")  \(package.file)")
                }
                print("\(valveFilesAreDownloaded() ? "downloaded" : "missing   ")  Valve's Steam files for Windows games (\(valveFiles.map(\.name).joined(separator: ", ")))")
            case "--download-runtimes":
                for package in microsoftPackages where !microsoftPackageIsDownloaded(package) {
                    print("downloading \(package.file) (\(package.size / 1_000_000) MB) from Microsoft")
                    if let failure = downloadMicrosoftPackage(package) { throw SteamSetup.SetupError.failed(failure) }
                }
                print("all \(microsoftPackages.count) of Microsoft's runtimes are downloaded")
                if !valveFilesAreDownloaded() {
                    print("downloading Valve's Steam files for Windows games (\(valveDownloadSize / 1_000_000) MB) from Valve")
                    if let failure = downloadValveFiles() { throw SteamSetup.SetupError.failed(failure) }
                }
                print("Valve's Steam files for Windows games are downloaded")
            case "--check-update":
                print("Tessera \(Updater.currentVersion) (build \(Updater.currentBuild)); update information from \(Updater.feed)")
                if let newer = try Updater.available() {
                    print("available: \(newer.version) (build \(newer.build)), \(newer.size / 1_000_000) MB")
                } else {
                    print("this is the latest version")
                }
            case "--update":
                guard let newer = try Updater.available() else { print("this is the latest version"); break }
                print("downloading Tessera \(newer.version) (\(newer.size / 1_000_000) MB)")
                let dmg = try Updater.download(newer)
                try Updater.install(newer, dmg: dmg, relaunch: args.contains("--reopen"))
                print("Tessera \(newer.version) is copied and checked; it goes into place as this program ends")
            case "--uninstall":
                try SteamSetup.uninstall()
                print("state: \(describe(SteamSetup.state()))")
            case "--restore-steam":
                try SteamSetup.restoreOriginals()
                print("Steam.app has Valve's own files again")
            default:
                print("usage: Tessera --status | --install [--all-games] [--keep-mappings] | --uninstall | --restore-steam | --play-windows-version APPID | --launch-entries APPID... | --runtimes | --download-runtimes | --check-update | --update [--reopen]")
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func describe(_ state: SteamSetup.State) -> String {
        switch state {
        case .notInApplications: return "running from a temporary copy - move Tessera to Applications"
        case .steamMissing: return "Steam is not installed"
        case .notInstalled: return "not set up"
        case .installed: return "ready"
        case .needsRepair(let why): return "needs repair: \(why)"
        }
    }
}
