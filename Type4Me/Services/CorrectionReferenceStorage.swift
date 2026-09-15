import Foundation
import Type4MeIntelliSenseCore

/// Small local store. It never imports history as consent or compiles references
/// into forced replacements. Malformed files surface errors instead of becoming
/// an empty store that a later confirmation could silently overwrite.
enum CorrectionReferenceStorage {
    static var fileURL: URL {
        HotwordStorage.userFileURL.deletingLastPathComponent().appendingPathComponent("correction-references.json")
    }
    private static let lock = NSLock()

    static func load(from url: URL = fileURL) throws -> [VocabularyCorrectionReference] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VocabularyCorrectionReference].self, from: Data(contentsOf: url))
    }

    static func save(_ references: [VocabularyCorrectionReference], to url: URL = fileURL) throws {
        lock.lock(); defer { lock.unlock() }
        guard references.allSatisfy(\.isValid) else { throw CorrectionReferenceError.invalidReference }
        let ordered = references.sorted { $0.confirmedAt > $1.confirmedAt }
        var seen = Set<String>()
        let bounded = Array(ordered.filter { seen.insert($0.comparisonKey).inserted }.prefix(256))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bounded)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum CorrectionReferenceError: Error {
    case unsupportedPersistence
    case invalidReference
}
