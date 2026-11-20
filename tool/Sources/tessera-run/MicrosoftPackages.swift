import CryptoKit
import Foundation

// MARK: - Microsoft's runtimes
//
// Microsoft's own installers that Tessera puts into every game's Windows folder: Visual C++ 2005-2022 (with MFC
// 10-14), MFC 4.2 and DirectX 9.0c (June 2010). Microsoft's licence does not let Tessera ship them, so they come from
// Microsoft's servers, checked against pinned SHA-256 (as winetricks 20260125 pins them; the 2015-2022 ones are
// Microsoft's fixed per-version addresses behind aka.ms/vs/17/release, Visual C++ 14.44).
//
// One file, used by both programs: the app (app/Sources/Tessera links to it) downloads them as soon as it opens and
// shows whether they are there; the game launcher installs them into Windows folders and downloads them itself only
// when the app has not.

struct MicrosoftPackage { let file: String; let url: String; let sha256: String; let size: Int64 }

let microsoftPackages: [MicrosoftPackage] = [
    .init(file: "vcredist_2005_x86.exe", url: "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE",
          sha256: "8648c5fc29c44b9112fe52f9a33f80e7fc42d10f3b5b42b2121542a13e44adfd", size: 2_710_520),
    .init(file: "vcredist_2005_x64.exe", url: "https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x64.EXE",
          sha256: "4487570bd86e2e1aac29db2a1d0a91eb63361fcaac570808eb327cd4e0e2240d", size: 3_179_000),
    .init(file: "vcredist_2008_x86.exe", url: "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x86.exe",
          sha256: "8742bcbf24ef328a72d2a27b693cc7071e38d3bb4b9b44dec42aa3d2c8d61d92", size: 4_483_040),
    .init(file: "vcredist_2008_x64.exe", url: "https://download.microsoft.com/download/5/D/8/5D8C65CB-C849-4025-8E95-C3966CAFD8AE/vcredist_x64.exe",
          sha256: "c5e273a4a16ab4d5471e91c7477719a2f45ddadb76c7f98a38fa5074a6838654", size: 5_211_080),
    .init(file: "vcredist_2010_x86.exe", url: "https://download.microsoft.com/download/5/B/C/5BC5DBB3-652D-4DCE-B14A-475AB85EEF6E/vcredist_x86.exe",
          sha256: "31d32fa39d52cac9a765a43660431f7a127eee784b54b2f5e2af3e2b763a1af8", size: 5_076_456),
    .init(file: "vcredist_2010_x64.exe", url: "https://download.microsoft.com/download/A/8/0/A80747C3-41BD-45DF-B505-E9710D2744E0/vcredist_x64.exe",
          sha256: "2fddbc3aaaab784c16bc673c3bae5f80929d5b372810dbc28649283566d33255", size: 5_677_032),
    .init(file: "vcredist_2012_x86.exe", url: "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x86.exe",
          sha256: "b924ad8062eaf4e70437c8be50fa612162795ff0839479546ce907ffa8d6e386", size: 6_554_576),
    .init(file: "vcredist_2012_x64.exe", url: "https://download.microsoft.com/download/1/6/B/16B06F60-3B20-4FF2-B699-5E9B7962F9AE/VSU_4/vcredist_x64.exe",
          sha256: "681be3e5ba9fd3da02c09d7e565adfa078640ed66a0d58583efad2c1e3cc4064", size: 7_186_992),
    .init(file: "vcredist_2013_x86.exe", url: "https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x86.exe",
          sha256: "89f4e593ea5541d1c53f983923124f9fd061a1c0c967339109e375c661573c17", size: 6_510_544),
    .init(file: "vcredist_2013_x64.exe", url: "https://download.microsoft.com/download/0/5/6/056dcda9-d667-4e27-8001-8a0c6971d6b1/vcredist_x64.exe",
          sha256: "20e2645b7cd5873b1fa3462b99a665ac8d6e14aae83ded9d875fea35ffdd7d7e", size: 7_201_032),
    .init(file: "VC_redist_2022.x86.exe", url: "https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe",
          sha256: "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64", size: 13_953_392),
    .init(file: "VC_redist_2022.x64.exe", url: "https://download.visualstudio.microsoft.com/download/pr/e9604e21-4b79-4096-a4b3-1b63d4b55b4d/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe",
          sha256: "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b", size: 25_635_768),
    .init(file: "VC6RedistSetup_deu.exe", url: "https://download.microsoft.com/download/vc60pro/Update/2/W9XNT4/EN-US/VC6RedistSetup_deu.exe",
          sha256: "c2eb91d9c4448d50e46a32fecbcc3b418706d002beab9b5f4981de552098cee7", size: 1_837_888),
    .init(file: "directx_Jun2010_redist.exe", url: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
          sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b", size: 100_275_120),
]

let microsoftPackagesTotalSize = microsoftPackages.reduce(Int64(0)) { $0 + $1.size }

/// Where both programs keep the downloads (one copy for every Windows folder).
let redistCache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Tessera/redist")

func sha256Hex(_ file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// True when the package is downloaded and matches its checksum (the size is compared first, which is instant).
func microsoftPackageIsDownloaded(_ package: MicrosoftPackage) -> Bool {
    let file = redistCache.appendingPathComponent(package.file)
    guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
          size.int64Value == package.size else { return false }
    return sha256Hex(file) == package.sha256
}

/// Downloads one package from Microsoft into the cache; it only lands there when its checksum matches.
/// `progress` gets the bytes received so far, about four times a second. Returns nil on success, else the reason.
func downloadMicrosoftPackage(_ package: MicrosoftPackage, progress: ((Int64) -> Void)? = nil) -> String? {
    let fm = FileManager.default
    try? fm.createDirectory(at: redistCache, withIntermediateDirectories: true)
    let file = redistCache.appendingPathComponent(package.file)
    let part = redistCache.appendingPathComponent(package.file + ".part-\(getpid())")
    try? fm.removeItem(at: part)
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-fsSL", "--retry", "2", "--connect-timeout", "20", "--max-time", "1800", "-o", part.path, package.url]
    curl.standardOutput = FileHandle.nullDevice
    curl.standardError = FileHandle.nullDevice
    do { try curl.run() } catch { return "could not start curl: \(error.localizedDescription)" }
    while curl.isRunning {
        Thread.sleep(forTimeInterval: 0.25)
        let received = ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        progress?(received)
    }
    guard curl.terminationStatus == 0 else {
        try? fm.removeItem(at: part)
        return curl.terminationStatus == 6 || curl.terminationStatus == 7 || curl.terminationStatus == 28
            ? "Microsoft's server could not be reached (no internet?)" : "the download of \(package.file) failed (curl \(curl.terminationStatus))"
    }
    guard sha256Hex(part) == package.sha256 else {
        try? fm.removeItem(at: part)
        return "\(package.file) did not match its checksum"
    }
    progress?(package.size)
    try? fm.removeItem(at: file)
    do { try fm.moveItem(at: part, to: file) } catch { return "could not keep \(package.file): \(error.localizedDescription)" }
    return nil
}
