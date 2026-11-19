import Foundation

/// The app's binary also works from Terminal, for scripts and testing:
///
///     Tessera.app/Contents/MacOS/Tessera --status
///     Tessera.app/Contents/MacOS/Tessera --install [--all-games] [--keep-mappings]
///     Tessera.app/Contents/MacOS/Tessera --uninstall
///
/// TESSERA_STEAM_APP=/path/to/Steam.app points every step at another copy of Steam.app.
enum CLI {
    static let commands = ["--status", "--install", "--uninstall", "--help"]

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
            case "--install":
                try SteamSetup.install(useForAllWindowsGames: args.contains("--all-games"),
                                       setDefaultTool: !args.contains("--keep-mappings"))
                print("state: \(describe(SteamSetup.state()))")
            case "--uninstall":
                try SteamSetup.uninstall()
                print("state: \(describe(SteamSetup.state()))")
            default:
                print("usage: Tessera --status | --install [--all-games] [--keep-mappings] | --uninstall")
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
