import Foundation

/// The user's vocabulary (`hotwords.json`). One list feeds the ASR hotword
/// boost, the accent-tolerant phonetic pass and the Intelli Sense vocabulary.
enum HotwordStorage {

    // MARK: - In-memory caches

    private static let cacheLock = NSLock()
    private static var cachedUser: [String]?       // guarded by cacheLock

    // MARK: - File paths

    private static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(AppDataLocation.profileDirectoryName)
    }

    /// User hotwords file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("hotwords.json") }

    // MARK: - Initialization

    private static let migratedKey = "tf_hotwords_migrated_to_file_v2"
    private static let oldUDKey = "tf_hotwords"

    /// Migrates old UserDefaults hotwords to user file (one-time).
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else { return }
        let raw = UserDefaults.standard.string(forKey: oldUDKey) ?? ""
        let oldWords = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if !oldWords.isEmpty {
            save(oldWords)
        }
    }

    // MARK: - User file (Settings UI)

    static func load() -> [String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedUser { return cached }
        let result = readFile(userFileURL)
        cachedUser = result
        return result
    }

    static let didChangeNotification = Notification.Name("HotwordStorageDidChange")

    /// Clear in-memory caches so next load re-reads from disk.
    /// Called when files are modified externally (e.g. by Claude Code skill).
    static func invalidateCache() {
        cacheLock.lock()
        cachedUser = nil
        cacheLock.unlock()
    }

    static func save(_ words: [String]) {
        try? saveOrThrow(words)
    }

    /// Persist user hotwords and surface file-system failures to callers that
    /// need all-or-nothing behavior (for example correction learning).
    static func saveOrThrow(_ words: [String]) throws {
        try saveOrThrow(words, notify: true)
    }

    /// The explicit overload keeps existing function references source-compatible.
    static func saveOrThrow(_ words: [String], notify: Bool) throws {
        try writeFileOrThrow(words, to: userFileURL)
        cacheLock.lock()
        cachedUser = nil
        cacheLock.unlock()
        if notify { notifyDidChange() }
    }

    static func notifyDidChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
        SenseVoiceServerManager.syncHotwordsAndRestart()
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return words
    }

    private static func writeFileOrThrow(_ words: [String], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(words)
        try data.write(to: url, options: .atomic)
    }
}
