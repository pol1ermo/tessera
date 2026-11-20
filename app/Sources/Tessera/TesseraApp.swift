import AppKit
import SwiftUI

@main
struct TesseraApp: App {
    @StateObject private var model = AppModel()

    init() { CLI.runIfRequested() }

    var body: some Scene {
        WindowGroup("Tessera") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 560)
                .preferredColorScheme(.dark)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refresh()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: SteamSetup.State = .notInstalled
    @Published var games: [Game] = []
    @Published var macOnly: [Game] = []       // installed Mac versions that cannot run
    @Published var busy: String?
    @Published var error: String?
    @Published var needsAppManagement = false

    init() {
        refresh()
        Task.detached(priority: .utility) { SteamSetup.syncAfterUpdate() }
    }

    func refresh() {
        state = SteamSetup.state()
        Task.detached(priority: .userInitiated) {
            let found = GameLibrary.windowsGames(), stuck = GameLibrary.macVersionsThatCannotRun()
            await MainActor.run { self.games = found; self.macOnly = stuck }
        }
    }

    func install(forAllGames: Bool) {
        perform("Setting up Tessera in Steam…") {
            try SteamSetup.install(useForAllWindowsGames: forAllGames)
            SteamSetup.openSteam()
        }
    }

    func uninstall() {
        perform("Removing Tessera from Steam…") {
            try SteamSetup.uninstall()
            SteamSetup.openSteam()
        }
    }

    func playWindowsVersion(_ game: Game) {
        perform("Switching \(game.name) to its Windows version…") {
            try SteamSetup.playWindowsVersion(appID: game.id)
            SteamSetup.openSteam()
        }
    }

    private func perform(_ message: String, _ work: @escaping () throws -> Void) {
        busy = message
        error = nil
        needsAppManagement = false
        Task.detached(priority: .userInitiated) {
            let failure: String?
            let permission: Bool
            do {
                try work(); failure = nil; permission = false
            } catch SteamSetup.SetupError.appManagement {
                failure = nil; permission = true
            } catch {
                failure = error.localizedDescription; permission = false
            }
            await MainActor.run {
                self.busy = nil
                self.error = failure
                self.needsAppManagement = permission
                self.refresh()
            }
        }
    }
}
