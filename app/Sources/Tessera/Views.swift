import AppKit
import SwiftUI

enum Section: Hashable {
    case steam
    case game(String)
    case macOnly(String)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: Section? = .steam

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Steam", systemImage: "gamecontroller").tag(Section.steam)
                if !model.games.isEmpty {
                    SwiftUI.Section("Windows games") {
                        ForEach(model.games) { game in
                            Text(game.name).lineLimit(1).tag(Section.game(game.id))
                        }
                    }
                }
                if !model.macOnly.isEmpty {
                    SwiftUI.Section("Mac versions that can't run") {
                        ForEach(model.macOnly) { game in
                            Text(game.name).lineLimit(1).tag(Section.macOnly(game.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            switch selection {
            case .game(let id):
                if let game = model.games.first(where: { $0.id == id }) {
                    GameView(game: game).id(game.id)
                } else {
                    SteamView()
                }
            case .macOnly(let id):
                if let game = model.macOnly.first(where: { $0.id == id }) {
                    MacOnlyGameView(game: game).id(game.id)
                } else {
                    SteamView()
                }
            default:
                SteamView()
            }
        }
    }
}

// MARK: - Steam

struct SteamView: View {
    @EnvironmentObject var model: AppModel
    @State private var forAllGames = true
    @State private var confirmRemove = false
    @AppStorage(AppModel.checksAtStartKey) private var checksForUpdatesAtStart = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tessera").font(.largeTitle.weight(.semibold))
                Text("Plays Windows games from your Steam library on this Mac, right from the Steam app.")
                    .foregroundStyle(.secondary)

                statusCard
                // what the set-up is doing or why it stopped belongs right under its card, where it is seen without scrolling
                if let busy = model.busy {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text(busy) }
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if model.needsAppManagement {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("macOS needs your OK to let Tessera change Steam.app", systemImage: "lock.shield")
                            .font(.headline)
                        Text("Open App Management, turn on Tessera, then click Set up in Steam again.")
                            .foregroundStyle(.secondary)
                        Button("Open App Management") { NSWorkspace.shared.open(SteamSetup.appManagementSettings) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.6)))
                }

                updateCard
                runtimesCard


                howItWorks
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .confirmationDialog("Remove Tessera from Steam?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.uninstall() }
        } message: {
            Text("Steam will quit and get its original files back. Your Windows games and their saves stay on this Mac: "
                 + "Tessera keeps the games out of Steam's sight, because Steam on its own would remove their files. "
                 + "Setting up again brings them back. To free the space instead, uninstall the games in Steam first.")
        }
    }

    @ViewBuilder private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .notInApplications:
                Label("Move Tessera to Applications first", systemImage: "folder.badge.plus").font(.headline)
                Text("Drag Tessera into your Applications folder, then open it from there. (Opened straight from a download, macOS runs a temporary copy that Steam could not find again.)")
                    .foregroundStyle(.secondary)
            case .steamMissing:
                Label("Steam isn't installed", systemImage: "xmark.circle").font(.headline)
                Text("Install Steam for Mac from store.steampowered.com, open it once, then come back here.")
                    .foregroundStyle(.secondary)
            case .notInstalled:
                Label("Not set up in Steam yet", systemImage: "circle.dashed").font(.headline)
                Toggle("Use Tessera for all Windows games", isOn: $forAllGames)
                Text("Steam will quit for a moment and open again.").font(.callout).foregroundStyle(.secondary)
                if !model.games.isEmpty {
                    // Steam without Tessera sees installed Windows games as not belonging on a Mac and empties their
                    // folders within minutes of starting (seen 22 Nov 2026: "removed depots", "0 mounted depots")
                    Label("Steam on its own removes the files of installed Windows games, so Tessera keeps your \(model.games.count) Windows game\(model.games.count == 1 ? "" : "s") out of Steam's sight until it is set up. They are not in Steam's library until then.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Button("Set up in Steam") { model.install(forAllGames: forAllGames) }
                    .buttonStyle(.borderedProminent).disabled(model.busy != nil)
            case .installed:
                Label("Ready. Windows games install and play in Steam", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("\(model.games.count) Windows game\(model.games.count == 1 ? "" : "s") installed.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Steam") { SteamSetup.openSteam() }.buttonStyle(.borderedProminent)
                    Button("Remove from Steam…") { confirmRemove = true }.disabled(model.busy != nil)
                }
            case .needsRepair(let why):
                Label("Needs repair: \(why)", systemImage: "wrench.and.screwdriver").font(.headline).foregroundStyle(.orange)
                Button("Repair") { model.install(forAllGames: false) }
                    .buttonStyle(.borderedProminent).disabled(model.busy != nil)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    /// Tessera's own version: the installed one, a newer one to install with one click, the download's progress.
    @ViewBuilder private var updateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.update {
            case .idle(let answer):
                HStack {
                    Label("Tessera \(Updater.currentVersion)", systemImage: "shippingbox").font(.headline)
                    Spacer()
                    Button("Check for Updates") { model.checkForUpdate(manual: true) }
                }
                if let answer { Text(answer).font(.callout).foregroundStyle(.secondary) }
            case .checking:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking for a newer Tessera…").font(.headline) }
            case .available(let newer):
                Label("Tessera \(newer.version) is available (you have \(Updater.currentVersion))", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                if !newer.notes.isEmpty {
                    ScrollView { Text(newer.notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 130)
                }
                Text("Tessera downloads it from GitHub (\(Self.megabytes(newer.size)) MB), checks it and opens again. Games, saves and settings stay as they are; Steam does not have to close.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Update Now") { model.installUpdate(newer) }.buttonStyle(.borderedProminent)
            case .downloading(let newer, let received):
                Label("Downloading Tessera \(newer.version)…", systemImage: "arrow.down.circle").font(.headline)
                ProgressView(value: Double(received), total: Double(max(newer.size, 1)))
                Text("\(Self.megabytes(received)) of \(Self.megabytes(newer.size)) MB from GitHub")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            case .installing(let newer):
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Installing Tessera \(newer.version)… it opens again in a moment").font(.headline) }
            case .failed(let why):
                Label("Tessera could not update itself", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Reason: \(why). Nothing was changed.").foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { model.checkForUpdate(manual: true) }.buttonStyle(.borderedProminent)
                    Button("Open the Download Page") { NSWorkspace.shared.open(Updater.releasesPage) }
                }
            }
            Toggle("Look for a newer version when Tessera opens", isOn: $checksForUpdatesAtStart)
                .font(.callout)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    /// Microsoft's runtimes and Valve's Steam files: whether they are downloaded, the download's progress, or why it failed.
    @ViewBuilder private var runtimesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.runtimes {
            case .checking:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Checking Microsoft's runtimes and Valve's Steam files…").font(.headline) }
            case .ready:
                Label("Microsoft's runtimes and Valve's Steam files are downloaded", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            case .downloading(let received, let total):
                Label("Downloading Microsoft's runtimes and Valve's Steam files…", systemImage: "arrow.down.circle").font(.headline)
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                Text("\(Self.megabytes(received)) of \(Self.megabytes(total)) MB from Microsoft and Valve")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            case .failed(let why):
                Label("Microsoft's runtimes or Valve's Steam files are not downloaded", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Reason: \(why). Tessera tries again when a game starts; until Valve's files are there, some games do not start.")
                    .foregroundStyle(.secondary)
                Button("Try Again") { model.downloadRuntimes() }.buttonStyle(.borderedProminent)
            }
            Text("Visual C++ 2005–2022 with MFC, MFC 4.2, DirectX 9.0c parts and Visual Basic 6, \(Self.megabytes(microsoftPackagesTotalSize)) MB. Microsoft's licence doesn't let Tessera include them, so Tessera downloads them from Microsoft; each game's Windows folder gets them once, at its first start. Valve's Steam files for Windows games (steamclient and Steam's script runner, \(Self.megabytes(valveDownloadSize)) MB) come the same way from Valve's update server: the Mac Steam client does not include them.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    static func megabytes(_ bytes: Int64) -> Int { Int((Double(bytes) / 1_000_000).rounded()) }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How it works").font(.headline)
            Text("Setting up adds one start-up setting to Steam.app so it loads Tessera, then signs Steam again on this Mac (Valve's signature does not allow additions). Tessera keeps Steam's original files and puts them back when you remove it.")
            Text("In Steam, Windows games show Install and Play like any Mac game. Each game gets its own Windows folder next to Steam's game files, so saves stay with your library.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - one game

struct GameView: View {
    let game: Game
    @State private var settings: GameSettings
    @State private var saved: GameSettings
    @State private var confirmReset = false

    init(game: Game) {
        self.game = game
        let s = GameSettings.load(game)
        _settings = State(initialValue: s)
        _saved = State(initialValue: s)
    }

    /// The main screen's desktop size and its largest mode, as Wine's display list names them (in points; the largest
    /// is the panel's own resolution, macOS's "low resolution" 1:1 mode).
    static let screenSizes: (desktop: String, full: String) = {
        guard let screen = NSScreen.main,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return ("the desktop size", "the screen's full size")
        }
        let desktop = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let big = modes.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return (desktop, desktop) }
        return (desktop, "\(big.width) × \(big.height)")
    }()

    var body: some View {
        Form {
            SwiftUI.Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.name).font(.title2.weight(.semibold))
                        Text(details).foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button("Play") { NSWorkspace.shared.open(URL(string: "steam://rungameid/\(game.id)")!) }
                        .buttonStyle(.borderedProminent)
                }
            }
            SwiftUI.Section("Graphics") {
                Picker("Translation", selection: $settings.graphics) {
                    ForEach(GameSettings.Graphics.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.graphics.detail).font(.callout).foregroundStyle(.secondary)
                Toggle("Show the Metal performance overlay", isOn: $settings.showHUD)
                Toggle("Ray tracing (DirectX Raytracing, D3DMetal)", isOn: $settings.raytracing)
                    .disabled(settings.graphics == .dxmt || settings.graphics == .dxvk || settings.graphics == .wined3d)
                Toggle("DLSS through MetalFX (D3DMetal 4)", isOn: $settings.metalFX)
                    .disabled(settings.graphics == .dxmt || settings.graphics == .dxvk || settings.graphics == .wined3d
                              || settings.graphics == .d3dmetal3)
                Text("For games with NVIDIA DLSS: the game sees an NVIDIA graphics card, and the DLSS upscaling chosen in its graphics settings runs on Apple's MetalFX.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Metal 4 graphics path (DirectX 12, macOS 27)", isOn: $settings.metal4)
                    .disabled(settings.graphics == .dxmt || settings.graphics == .dxvk || settings.graphics == .wined3d
                              || settings.graphics == .d3dmetal3 || !GameSettings.d3dMetal4Runs)
                Text("Off by default: with the Metal 3 path a frame reaches the screen a few milliseconds sooner at the same frame rate (measured), so mouse and controller feel more direct. Turn it on only if a game misbehaves without it.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Resolutions up to \(Self.screenSizes.full)", isOn: $settings.fullResolution)
                Text("On (the default), a game that may draw through D3DMetal's DirectX 10–12 starts on the screen's full \(Self.screenSizes.full), because D3DMetal offers sizes only up to the desktop: its menu then lists every size, sharper at the bigger sizes, more work for the GPU, and small windows such as launchers look smaller. 32-bit games, games drawing through Direct3D 9, OpenGL or Vulkan, games on DXMT, DXVK or WineD3D and Chromium-based games (RPG Maker MV/MZ) list every size on the Mac desktop size (\(Self.screenSizes.desktop)) and keep it. Off, every game uses the Mac desktop size.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Windows") {
                Toggle("Microsoft .NET Framework 4.8", isOn: $settings.dotNet)
                Text("For .NET launchers that Wine's own .NET cannot run (Assetto Corsa's gets it automatically). Installed into this game's Windows folder once, after you agree: 123 MB from Microsoft, about five minutes.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SwiftUI.Section("Steam") {
                Toggle("Steam overlay (Shift+Tab)", isOn: $settings.steamOverlay)
                Text("Friends, chat, guides and Steam's FPS counter inside the game. Turn it off for the steadiest frame times: it loads once, about a minute after the game starts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SwiftUI.Section {
                HStack {
                    Button("Open Log") { NSWorkspace.shared.open(game.logFile) }
                        .disabled(!FileManager.default.fileExists(atPath: game.logFile.path))
                    Button("Show Windows Folder") {
                        if let prefix = game.prefix { NSWorkspace.shared.activateFileViewerSelecting([prefix]) }
                    }
                    .disabled(game.prefix == nil)
                    Spacer()
                    Button("Reset Windows Folder…", role: .destructive) { confirmReset = true }
                        .disabled(game.prefix == nil)
                }
            } footer: {
                Text("Changes apply the next time the game starts.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, new in
            guard new != saved else { return }
            try? new.save(game)
            saved = new
        }
        .confirmationDialog("Reset the Windows folder of \(game.name)?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                if let prefix = game.prefix { try? FileManager.default.trashItem(at: prefix, resultingItemURL: nil) }
            }
        } message: {
            Text("The folder goes to the Trash and a fresh one is made at the next start. Saves kept in Steam Cloud come back; saves stored only on this Mac are in the Trash.")
        }
    }

    private var details: String {
        var parts = [ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file)]
        if let played = game.lastPlayed {
            parts.append("last played " + played.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - a game whose Mac version cannot run

struct MacOnlyGameView: View {
    @EnvironmentObject var model: AppModel
    let game: Game
    @State private var confirm = false

    private var ready: Bool { if case .installed = model.state { return true } else { return false } }

    var body: some View {
        Form {
            SwiftUI.Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.name).font(.title2.weight(.semibold))
                    Text("Mac version installed · \(ByteCountFormatter.string(fromByteCount: game.sizeOnDisk, countStyle: .file))")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            SwiftUI.Section("This Mac version can't run") {
                Text("Steam installed this game's Mac version, a 32-bit program. macOS 10.15 and later run only 64-bit programs, so it can't start. Tessera can play the game's Windows version instead: Steam downloads the Windows files in place of the Mac ones, and the game then appears under Windows games.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Play the Windows Version…") { confirm = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy != nil || !ready)
                    if let busy = model.busy {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout)
                    }
                }
                if !ready {
                    Text("Tessera isn't ready in Steam yet: open Steam in the sidebar to set it up or repair it.").font(.callout).foregroundStyle(.orange)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Play the Windows version of \(game.name)?", isPresented: $confirm) {
            Button("Switch to the Windows Version") { model.playWindowsVersion(game) }
        } message: {
            Text("Steam will quit for a moment and open again, then download the Windows version in place of the Mac one.")
        }
    }
}
