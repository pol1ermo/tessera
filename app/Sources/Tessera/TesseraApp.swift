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
    @Published var runtimes: Runtimes = .checking
    @Published var update: UpdateState = .idle(nil)

    /// Tessera's own update (Updater.swift) as the Steam page shows it
    enum UpdateState: Equatable {
        case idle(String?)              // nothing to show, or the answer of the last check
        case checking
        case available(UpdateManifest)
        case downloading(UpdateManifest, received: Int64)
        case installing(UpdateManifest)
        case failed(String)
    }
    nonisolated static let checksAtStartKey = "checkForUpdatesAtStart", lastCheckKey = "lastUpdateCheck"

    /// Microsoft's runtimes (MicrosoftPackages.swift) and Valve's Steam files (ValveFiles.swift) as the Steam page shows them
    enum Runtimes: Equatable {
        case checking
        case ready
        case downloading(received: Int64, total: Int64)
        case failed(String)
    }

    init() {
        refresh()
        Task.detached(priority: .utility) {
            SteamSetup.syncAfterUpdate()
            Updater.cleanUp()
            // Steam closed (a restart of the Mac leaves the records visible): park them, so that a Steam started without
            // Tessera cannot remove the games' files; with Tessera's library running this does nothing
            if SteamSetup.steamProcesses.isEmpty, SteamSetup.parkingIsSafe { SteamSetup.parkGames() }
        }
        // as soon as Tessera opens: what is missing comes from Microsoft and Valve now, not at a game's first start
        downloadRuntimes()
        // a newer Tessera: asked at most every six hours, and not at all when the person switched the check off
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.checksAtStartKey) as? Bool ?? true,
           Date().timeIntervalSince1970 - defaults.double(forKey: Self.lastCheckKey) > 6 * 3600 {
            checkForUpdate(manual: false)
        }
    }

    /// Asks GitHub's latest release whether it is newer. A check Tessera makes by itself stays quiet when it fails
    /// (no internet); one the person asked for says why.
    func checkForUpdate(manual: Bool) {
        switch update {
        case .checking, .downloading, .installing: return
        default: break
        }
        update = .checking
        Task.detached(priority: .utility) {
            let result: UpdateState
            do {
                if let newer = try Updater.available() {
                    result = .available(newer)
                } else {
                    result = .idle("This is the latest version.")
                }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            } catch {
                result = manual ? .failed(error.localizedDescription) : .idle(nil)
            }
            await MainActor.run { self.update = result }
        }
    }

    /// Downloads and checks the new version, copies it next to this one, and quits so the swap can happen; the new
    /// version opens by itself.
    func installUpdate(_ manifest: UpdateManifest) {
        update = .downloading(manifest, received: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let dmg = try Updater.download(manifest) { received in
                    Task { @MainActor in
                        if case .downloading = self.update { self.update = .downloading(manifest, received: received) }
                    }
                }
                await MainActor.run { self.update = .installing(manifest) }
                try Updater.install(manifest, dmg: dmg, relaunch: true)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                await MainActor.run { self.update = .failed(error.localizedDescription) }
            }
        }
    }

    private var runtimesBusy = false

    /// Checks the downloads (sizes, then checksums) and fetches the missing ones from Microsoft, with progress.
    func downloadRuntimes() {
        guard !runtimesBusy else { return }
        runtimesBusy = true
        runtimes = .checking
        Task.detached(priority: .utility) {
            let missing = microsoftPackages.filter { !microsoftPackageIsDownloaded($0) }
            // Valve's Steam files for Windows games (ValveFiles.swift): the Mac Steam client does not include them
            let needValve = !valveFilesAreDownloaded()
            let total = missing.reduce(Int64(0)) { $0 + $1.downloadSize } + (needValve ? valveDownloadSize : 0)
            var done: Int64 = 0
            if !missing.isEmpty || needValve { await MainActor.run { self.runtimes = .downloading(received: 0, total: total) } }
            if needValve {
                // first: without them a game does not reach Steam, without Microsoft's it mostly still starts
                let failure = downloadValveFiles { received in
                    Task { @MainActor in
                        if case .downloading = self.runtimes {
                            self.runtimes = .downloading(received: min(received, valveDownloadSize), total: total)
                        }
                    }
                }
                if let failure {
                    await MainActor.run { self.runtimes = .failed(failure); self.runtimesBusy = false }
                    return
                }
                done += valveDownloadSize
            }
            for package in missing {
                let before = done
                let failure = downloadMicrosoftPackage(package) { received in
                    Task { @MainActor in   // a late update never turns "ready" or "failed" back into "downloading"
                        if case .downloading = self.runtimes {
                            self.runtimes = .downloading(received: before + min(received, package.downloadSize), total: total)
                        }
                    }
                }
                if let failure {
                    await MainActor.run { self.runtimes = .failed(failure); self.runtimesBusy = false }
                    return
                }
                done += package.downloadSize
            }
            await MainActor.run { self.runtimes = .ready; self.runtimesBusy = false }
        }
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
