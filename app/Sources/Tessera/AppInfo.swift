import Foundation

/// What Steam itself knows about an app: appcache/appinfo.vdf, the client's copy of every app's configuration (a
/// binary key/value file; format versions 0x27 to 0x29 are read). Tessera asks one thing: an app's launch entries,
/// the programs Steam can start and the systems each one is for.
enum AppInfo {
    struct LaunchEntry: Equatable {
        var executable: String
        var oslist: String              // "windows", "macos,linux", ...; empty = every system

        /// Steam on a Mac can start this entry without a compatibility tool.
        var startsOnMac: Bool {
            oslist.isEmpty || oslist.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "macos" }
        }
    }

    static var file: URL { Paths.steamData.appendingPathComponent("appcache/appinfo.vdf") }

    /// The launch entries of the given apps. An app that is missing from the result is not in Steam's file (or the
    /// file is missing or of a format this code does not know): nothing is known about it.
    static func launchEntries(of apps: Set<String>, in file: URL = AppInfo.file) -> [String: [LaunchEntry]] {
        guard !apps.isEmpty, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [:] }
        var reader = Reader(bytes: [UInt8](data))
        return reader.launchEntries(of: apps)
    }

    /// A value of the key/value tree: only maps and strings matter here.
    indirect enum Node {
        case map([String: Node])
        case string(String)
        case other

        subscript(key: String) -> Node? { if case .map(let m) = self { return m[key] } else { return nil } }
        var text: String? { if case .string(let s) = self { return s } else { return nil } }
    }

    struct Reader {
        let bytes: [UInt8]
        var keys: [String]?             // format 0x29: keys are numbers into this table

        init(bytes: [UInt8]) { self.bytes = bytes }

        func u32(_ at: Int) -> UInt32? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }

        /// A zero-ended string and the place after it.
        func cstring(_ at: Int) -> (String, Int)? {
            guard at >= 0, at < bytes.count, let end = bytes[at...].firstIndex(of: 0) else { return nil }
            return (String(decoding: bytes[at..<end], as: UTF8.self), end + 1)
        }

        mutating func launchEntries(of apps: Set<String>) -> [String: [LaunchEntry]] {
            guard let magic = u32(0), magic >> 8 == 0x07_5644 else { return [:] }
            let version = Int(magic & 0xFF)
            guard (0x27...0x29).contains(version) else { return [:] }
            var at = 8
            if version >= 0x29 {
                guard let low = u32(8), let high = u32(12), high == 0, let count = u32(Int(low)), count < 5_000_000 else { return [:] }
                var table: [String] = []
                table.reserveCapacity(Int(count))
                var p = Int(low) + 4
                for _ in 0..<count {
                    guard let (s, next) = cstring(p) else { return [:] }
                    table.append(s)
                    p = next
                }
                keys = table
                at = 16
            }
            // per app: id, size of what follows, then state, time, token (8), hash (20), change number,
            // from 0x28 a second hash (20), then the key/value tree
            let header = 4 + 4 + 8 + 20 + 4 + (version >= 0x28 ? 20 : 0)
            var found: [String: [LaunchEntry]] = [:]
            while let id = u32(at), id != 0, let size = u32(at + 4) {
                let start = at + 8
                if apps.contains(String(id)), let (tree, _) = node(at: start + header, depth: 0) {
                    var entries: [LaunchEntry] = []
                    if case .map(let launch)? = tree["appinfo"]?["config"]?["launch"] {
                        for key in launch.keys.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                            guard let entry = launch[key], let exe = entry["executable"]?.text else { continue }
                            entries.append(LaunchEntry(executable: exe, oslist: entry["config"]?["oslist"]?.text ?? ""))
                        }
                    }
                    found[String(id)] = entries
                }
                at = start + Int(size)
            }
            return found
        }

        /// One map of the tree, starting at its first entry; nil when the bytes are not what this code knows.
        func node(at start: Int, depth: Int) -> (Node, Int)? {
            guard depth < 64 else { return nil }
            var map: [String: Node] = [:]
            var p = start
            while p < bytes.count {
                let type = bytes[p]
                p += 1
                if type == 8 || type == 11 { return (.map(map), p) }
                let key: String
                if let table = keys {
                    guard let i = u32(p), Int(i) < table.count else { return nil }
                    key = table[Int(i)]
                    p += 4
                } else {
                    guard let (s, next) = cstring(p) else { return nil }
                    key = s
                    p = next
                }
                switch type {
                case 0:
                    guard let (child, next) = node(at: p, depth: depth + 1) else { return nil }
                    map[key] = child
                    p = next
                case 1:
                    guard let (s, next) = cstring(p) else { return nil }
                    map[key] = .string(s)
                    p = next
                case 2, 3, 4, 6: map[key] = .other; p += 4          // number, float, pointer, colour
                case 7, 10: map[key] = .other; p += 8               // 64-bit numbers
                default: return nil
                }
            }
            return nil
        }
    }
}
