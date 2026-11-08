import CryptoKit
import Foundation

enum VerificationError: Error { case invalidFeed, invalidBundle, invalidSignature, versionMismatch }

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Usage: verify-update.swift archive.zip appcast.xml") }
let archive = URL(fileURLWithPath: arguments[1])
let feed = URL(fileURLWithPath: arguments[2])
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("reprise-update-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

do {
    let extract = Process()
    extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    extract.arguments = ["-x", "-k", archive.path, temporary.path]
    try extract.run()
    extract.waitUntilExit()
    guard extract.terminationStatus == 0 else { throw VerificationError.invalidBundle }
    let plistURL = temporary.appendingPathComponent("Reprise.app/Contents/Info.plist")
    guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
          plist["CFBundleIdentifier"] as? String == "app.reprise.macos",
          let version = plist["CFBundleVersion"] as? String,
          let encodedKey = plist["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: encodedKey) else { throw VerificationError.invalidBundle }
    let document = try XMLDocument(data: Data(contentsOf: feed))
    guard let item = try document.nodes(forXPath: "/rss/channel/item").first as? XMLElement,
          let enclosure = item.elements(forName: "enclosure").first,
          let encodedSignature = enclosure.attributes?.first(where: { $0.localName == "edSignature" })?.stringValue,
          let signature = Data(base64Encoded: encodedSignature) else { throw VerificationError.invalidFeed }
    let feedVersion = item.elements(forLocalName: "version", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle").first?.stringValue
    guard feedVersion == version else { throw VerificationError.versionMismatch }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: try Data(contentsOf: archive)) else { throw VerificationError.invalidSignature }
    print("Verified archive signature against its embedded public key; feed and app version \(version) match.")
} catch {
    try? FileManager.default.removeItem(at: temporary)
    FileHandle.standardError.write(Data("Update verification failed: \(error)\n".utf8))
    exit(1)
}
