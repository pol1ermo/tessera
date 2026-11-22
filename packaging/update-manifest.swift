// update-manifest - makes and checks the small file Tessera's in-app update reads (update.json, a release asset).
//
//   update-manifest keygen                         make the signing key once (prints only the PUBLIC key)
//   update-manifest sign DMG VERSION BUILD NOTES   print update.json for a release (NOTES: a text file, shown in the app)
//   update-manifest verify UPDATE.JSON DMG PUBKEY  check a manifest against a disk image, as the app does
//
// The key signs everything in the file: version, build, the image's name, size and SHA-256, the oldest macOS, the notes.
// only an image whose manifest verifies, so a release cannot be swapped for something else on the way. The private key
// stays on the release Mac in ~/.config/tessera/update-signing-key (mode 600) and is never printed or committed.
import CryptoKit
import Foundation

let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tessera/update-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("update-manifest: \(message)\n".utf8))
    exit(1)
}

/// The exact bytes that are signed; the app builds the same text from the manifest it downloaded.
func signedText(version: String, build: String, dmg: String, size: Int64, sha256: String, minimum: String, notes: String) -> Data {
    let notesHash = SHA256.hash(data: Data(notes.utf8)).map { String(format: "%02x", $0) }.joined()
    return Data("tessera-update 2\n\(version)\n\(build)\n\(dmg)\n\(size)\n\(sha256)\n\(minimum)\n\(notesHash)\n".utf8)
}

func sha256Hex(_ url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { fail("cannot read \(url.path)") }
    var hasher = SHA256()
    while true {
        let chunk = handle.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyFile, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("no signing key at \(keyFile.path) (run: update-manifest keygen)")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    let fm = FileManager.default
    if !fm.fileExists(atPath: keyFile.path) {
        let key = Curve25519.Signing.PrivateKey()
        try? fm.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: keyFile.path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                            attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(keyFile.path)") }
    }
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count == 5 else { fail("usage: update-manifest sign DMG VERSION BUILD NOTES") }
    let dmg = URL(fileURLWithPath: args[1])
    guard let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path))?[.size] as? NSNumber else { fail("cannot read \(dmg.path)") }
    let sha = sha256Hex(dmg)
    let notes = ((try? String(contentsOfFile: args[4], encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let text = signedText(version: args[2], build: args[3], dmg: dmg.lastPathComponent, size: size.int64Value, sha256: sha,
                          minimum: "14.0", notes: notes)
    guard let signature = try? privateKey().signature(for: text) else { fail("signing failed") }
    let manifest: [String: Any] = [
        "version": args[2], "build": args[3], "dmg": dmg.lastPathComponent, "size": size.int64Value, "sha256": sha,
        "minimumSystemVersion": "14.0", "notes": notes,
        "signature": signature.base64EncodedString(),
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { fail("cannot write the manifest") }
    print(String(decoding: json, as: UTF8.self))
case "verify":
    guard args.count == 4 else { fail("usage: update-manifest verify UPDATE.JSON DMG PUBKEY") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = m["version"] as? String, let build = m["build"] as? String, let name = m["dmg"] as? String,
          let size = (m["size"] as? NSNumber)?.int64Value, let sha = m["sha256"] as? String,
          let signature = Data(base64Encoded: m["signature"] as? String ?? ""),
          let raw = Data(base64Encoded: args[3]), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    else { fail("the manifest or the key cannot be read") }
    let dmg = URL(fileURLWithPath: args[2])
    let realSize = ((try? FileManager.default.attributesOfItem(atPath: dmg.path))?[.size] as? NSNumber)?.int64Value
    guard key.isValidSignature(signature, for: signedText(version: version, build: build, dmg: name, size: size, sha256: sha,
                                                          minimum: m["minimumSystemVersion"] as? String ?? "", notes: m["notes"] as? String ?? ""))
    else { fail("the signature does NOT match") }
    guard realSize == size, sha256Hex(dmg) == sha, dmg.lastPathComponent == name else { fail("the disk image is not the one the manifest describes") }
    print("ok: \(name) is Tessera \(version) (build \(build)), signature valid")
default:
    fail("usage: update-manifest keygen | sign DMG VERSION BUILD NOTES | verify UPDATE.JSON DMG PUBKEY")
}
