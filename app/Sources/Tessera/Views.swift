import AppKit
import SwiftUI

enum Section: Hashable {
    case steam
    case game(String)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tessera").font(.largeTitle.weight(.semibold))
                Text("Plays Windows games from your Steam library on this Mac, right from the Steam app.")
                    .foregroundStyle(.secondary)

                statusCard

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

                howItWorks
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .confirmationDialog("Remove Tessera from Steam?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.uninstall() }
        } message: {
            Text("Steam will quit and get its original files back. Your games and their saves stay where they are.")
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
                    .disabled(settings.graphics == .dxmt || settings.graphics == .wined3d)
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
