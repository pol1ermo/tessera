import Foundation

/// Every location Tessera reads or writes, in one place.
///
/// Steam is told to load Tessera's library at start-up. If that file ever disappeared, macOS would refuse to start
/// Steam at all, so everything Steam refers to lives in a stable folder of its own (Application Support), never
/// inside the app bundle, which people move and delete.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // Tessera's own stable folder
    static let support = home.appendingPathComponent("Library/Application Support/Tessera")
    static let steamLibrary = support.appendingPathComponent("steam/tessera_steam.dylib")
    static let compatRoot = support.appendingPathComponent("compat")
    static let compatTool = compatRoot.appendingPathComponent("tessera")
    static let runtimeLink = support.appendingPathComponent("runtime")
    static let gameSettings = support.appendingPathComponent("games")
    /// finished Windows folders the launcher clones for new games (one per runtime version)
    static let prefixTemplates = support.appendingPathComponent("templates")
    static let backups = support.appendingPathComponent("backups")
    static let logs = home.appendingPathComponent("Library/Logs/Tessera")

    // Steam (TESSERA_STEAM_APP points everything at another copy of Steam.app, for testing)
    static let steamApp: URL = {
        if let custom = ProcessInfo.processInfo.environment["TESSERA_STEAM_APP"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let user = home.appendingPathComponent("Applications/Steam.app")
        let system = URL(fileURLWithPath: "/Applications/Steam.app")
        return FileManager.default.fileExists(atPath: system.path) || !FileManager.default.fileExists(atPath: user.path) ? system : user
    }()
    static let steamData = home.appendingPathComponent("Library/Application Support/Steam")
    static let steamConfig = steamData.appendingPathComponent("config/config.vdf")
    static let steamClient = steamData.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    static let steamApps = steamData.appendingPathComponent("steamapps")

    // inside Tessera.app
    static var bundledResources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: ".") }
    static var bundledRuntime: URL { bundledResources.appendingPathComponent("Runtime") }
    static var bundledSteamLibrary: URL { bundledResources.appendingPathComponent("steam/tessera_steam.dylib") }
    static var bundledCompatTool: URL { bundledResources.appendingPathComponent("compat/tessera") }

    static func settingsFile(appID: String) -> URL { gameSettings.appendingPathComponent("\(appID).env") }
    static func gameLog(appID: String) -> URL { logs.appendingPathComponent("game-\(appID).log") }
}
