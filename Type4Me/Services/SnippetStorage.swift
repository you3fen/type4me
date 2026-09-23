import Foundation
import Type4MeIntelliSenseCore
import os

/// Exact trigger → replacement rules: global (`snippets.json`) plus optional
/// per-app overrides (`app-snippets/`). App rules win on trigger conflict.
enum SnippetStorage {

    // MARK: - In-memory caches

    private static let fileCacheLock = NSLock()
    private static var cachedUser: [(trigger: String, value: String)]?     // guarded by fileCacheLock

    // MARK: - File paths

    private static var appSupportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(AppDataLocation.profileDirectoryName)
    }

    /// User snippets file (managed by Settings UI)
    static var userFileURL: URL { appSupportDir.appendingPathComponent("snippets.json") }

    // MARK: - Codable model

    private struct Entry: Codable {
        let trigger: String
        let replacement: String
    }

    // MARK: - Initialization

    private static let migratedKey = "tf_snippets_migrated_to_file_v2"
    private static let oldUDKey = "tf_snippets"

    /// Migrates old UserDefaults snippets to user file (one-time).
    static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        // Migrate old UserDefaults to user file (skip if user file already exists)
        guard !FileManager.default.fileExists(atPath: userFileURL.path) else { return }
        guard let data = UserDefaults.standard.data(forKey: oldUDKey),
              let pairs = try? JSONDecoder().decode([[String]].self, from: data)
        else { return }

        let oldSnippets = pairs.compactMap { pair -> (trigger: String, value: String)? in
            guard pair.count == 2 else { return nil }
            return (trigger: pair[0], value: pair[1])
        }

        if !oldSnippets.isEmpty {
            save(oldSnippets)
        }
    }

    // MARK: - User file (Settings UI)

    static func load() -> [(trigger: String, value: String)] {
        fileCacheLock.lock()
        defer { fileCacheLock.unlock() }
        if let cached = cachedUser { return cached }
        let result = readFile(userFileURL)
        cachedUser = result
        return result
    }

    static let didChangeNotification = Notification.Name("SnippetStorageDidChange")

    static func save(_ snippets: [(trigger: String, value: String)]) {
        try? saveOrThrow(snippets)
    }

    /// Persist global user snippets while surfacing file-system failures.
    /// The regular Settings UI intentionally keeps its best-effort behavior.
    static func saveOrThrow(_ snippets: [(trigger: String, value: String)]) throws {
        try writeFileOrThrow(snippets, to: userFileURL)
        invalidateCache()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - App-specific snippets

    /// Registered app for per-app snippet overrides.
    struct AppInfo: Codable, Identifiable, Equatable {
        let bundleId: String
        let name: String
        var id: String { bundleId }
    }

    // MARK: - App-specific file paths

    private static var appSnippetsDir: URL {
        appSupportDir.appendingPathComponent("app-snippets")
    }

    private static var registryFileURL: URL {
        appSnippetsDir.appendingPathComponent("registry.json")
    }

    private static func appSnippetFileURL(bundleId: String) -> URL {
        appSnippetsDir.appendingPathComponent("\(bundleId).json")
    }

    // MARK: - Registry CRUD

    static func loadRegistry() -> [AppInfo] {
        guard let data = try? Data(contentsOf: registryFileURL),
              let apps = try? JSONDecoder().decode([AppInfo].self, from: data)
        else { return [] }
        return apps
    }

    static func saveRegistry(_ apps: [AppInfo]) {
        let dir = registryFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(apps) else { return }
        try? data.write(to: registryFileURL, options: .atomic)
    }

    static func addApp(_ app: AppInfo) {
        var apps = loadRegistry()
        guard !apps.contains(where: { $0.bundleId == app.bundleId }) else { return }
        apps.append(app)
        saveRegistry(apps)
    }

    static func removeApp(bundleId: String) {
        var apps = loadRegistry()
        apps.removeAll { $0.bundleId == bundleId }
        saveRegistry(apps)
        // Delete the per-app snippet file
        try? FileManager.default.removeItem(at: appSnippetFileURL(bundleId: bundleId))
        // Invalidate this app's compiled cache
        _ = appCacheLock.withLock { $0.removeValue(forKey: bundleId) }
    }

    // MARK: - Per-app snippet load/save

    static func loadAppSnippets(bundleId: String) -> [(trigger: String, value: String)] {
        return readFile(appSnippetFileURL(bundleId: bundleId))
    }

    static func saveAppSnippets(_ snippets: [(trigger: String, value: String)], bundleId: String) {
        writeFile(snippets, to: appSnippetFileURL(bundleId: bundleId))
        _ = appCacheLock.withLock { $0.removeValue(forKey: bundleId) }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    // MARK: - Compiled cache

    private struct CompiledRule {
        let regex: NSRegularExpression
        let pattern: String   // original flex pattern (for conflict detection)
        let template: String  // pre-escaped replacement
        let trigger: String
        let value: String
    }

    /// Thread-safe compiled rules cache for global snippets. Rebuilt only when snippets change.
    private static let cacheLock = OSAllocatedUnfairLock(initialState: [CompiledRule]?(nil))

    /// Thread-safe compiled rules cache for per-app snippets, keyed by bundleId.
    private static let appCacheLock = OSAllocatedUnfairLock(initialState: [String: [CompiledRule]]())

    /// Call after saving either file to force recompilation on next apply.
    static func invalidateCache() {
        cacheLock.withLock { $0 = nil }
        appCacheLock.withLock { $0.removeAll() }
        fileCacheLock.lock()
        cachedUser = nil
        fileCacheLock.unlock()
    }

    private static func compiledRules() -> [CompiledRule] {
        if let cached = cacheLock.withLock({ $0 }) { return cached }
        let rules = compile(load())
        cacheLock.withLock { $0 = rules }
        return rules
    }

    private static func compiledAppRules(bundleId: String) -> [CompiledRule] {
        if let cached = appCacheLock.withLock({ $0[bundleId] }) { return cached }
        let rules = compile(loadAppSnippets(bundleId: bundleId))
        appCacheLock.withLock { $0[bundleId] = rules }
        return rules
    }

    // MARK: - Apply (merge both stores)

    /// Applies global + app-specific snippets, reporting which rules actually
    /// rewrote the text and which scope each came from.
    ///
    /// The output and the report come from one pass on purpose. Asking later which
    /// rules "would" match re-runs whatever rules exist by then, and describes rules
    /// that may have been edited, deleted or added since the text was produced.
    static func applyEffectiveTracking(to text: String, bundleId: String?, onMatch: ((String, Int, Int) -> Void)? = nil) -> SnippetApplication {
        let appRules: [CompiledRule]
        if let bundleId, !bundleId.isEmpty {
            appRules = compiledAppRules(bundleId: bundleId)
        } else {
            appRules = []
        }
        return apply(to: text, globalRules: compiledRules(), appRules: appRules, bundleId: bundleId, onMatch: onMatch)
    }

    /// Rule application over explicit lists, independent of stored snippets.
    static func apply(
        to text: String,
        globalRules: [(trigger: String, value: String)],
        appRules: [(trigger: String, value: String)],
        bundleId: String?,
        onMatch: ((String, Int, Int) -> Void)? = nil
    ) -> SnippetApplication {
        let hasScope = !(bundleId ?? "").isEmpty
        return apply(
            to: text,
            globalRules: compile(globalRules),
            appRules: hasScope ? compile(appRules) : [],
            bundleId: bundleId,
            onMatch: onMatch
        )
    }

    private static func compile(_ snippets: [(trigger: String, value: String)]) -> [CompiledRule] {
        snippets.compactMap { snippet -> CompiledRule? in
            let pattern = buildFlexPattern(snippet.trigger)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return CompiledRule(
                regex: regex,
                pattern: pattern,
                template: NSRegularExpression.escapedTemplate(for: snippet.value),
                trigger: snippet.trigger,
                value: snippet.value
            )
        }
    }

    /// Global rules run first, skipping any whose pattern an app rule overrides;
    /// app rules run last. A rule is reported only when it matched at the point it
    /// ran, so a rule that fires on an earlier rule's output is included too.
    private static func apply(
        to text: String,
        globalRules: [CompiledRule],
        appRules: [CompiledRule],
        bundleId: String?,
        onMatch: ((String, Int, Int) -> Void)?
    ) -> SnippetApplication {
        let appPatterns = Set(appRules.map(\.pattern))
        var result = text
        var applied: [AppliedSnippetRule] = []

        func run(_ rule: CompiledRule, scope: String?, index: Int) {
            let range = NSRange(result.startIndex..., in: result)
            let count = rule.regex.numberOfMatches(in: result, range: range)
            guard count > 0 else { return }
            onMatch?(scope == nil ? "global" : "app", index, count)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
            applied.append(AppliedSnippetRule(trigger: rule.trigger, value: rule.value, bundleId: scope))
        }

        for (index, rule) in globalRules.enumerated() where !appPatterns.contains(rule.pattern) {
            run(rule, scope: nil, index: index)
        }
        for (index, rule) in appRules.enumerated() {
            run(rule, scope: bundleId, index: index)
        }
        return SnippetApplication(text: result, appliedRules: applied)
    }

    // MARK: - Pattern building

    /// Builds a regex that matches the trigger case-insensitively and space-insensitively.
    /// Strips all whitespace from trigger, then inserts `\s*` between each character.
    /// Uses ASCII-only word boundaries (not `\b`) so CJK/Latin boundaries work correctly.
    private static func buildFlexPattern(_ trigger: String) -> String {
        VocabularyTermIdentity.pattern(trigger, protectsIdentifiers: false)
    }

    // MARK: - File I/O helpers

    private static func readFile(_ url: URL) -> [(trigger: String, value: String)] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries.map { (trigger: $0.trigger, value: $0.replacement) }
    }

    private static func writeFile(_ snippets: [(trigger: String, value: String)], to url: URL) {
        try? writeFileOrThrow(snippets, to: url)
    }

    private static func writeFileOrThrow(_ snippets: [(trigger: String, value: String)], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries = snippets.map { Entry(trigger: $0.trigger, replacement: $0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(entries)
        try data.write(to: url, options: .atomic)
    }
}

/// One replacement rule that rewrote text, and the scope it came from.
struct AppliedSnippetRule: Codable, Equatable, Hashable, Sendable {
    let trigger: String
    let value: String
    /// `nil` for a global rule; the app's bundle identifier for an app rule.
    let bundleId: String?
    /// `nil` for a stored snippet rule. Set when the rewrite came from another
    /// deterministic pass, so history does not look for a snippet that never existed.
    var origin: Origin? = nil

    enum Origin: String, Codable, Sendable {
        /// Accent-tolerant pinyin match against the user's vocabulary.
        case phoneticVocabulary
    }
}

/// Replacement output together with the rules that produced it.
struct SnippetApplication: Equatable, Sendable {
    let text: String
    let appliedRules: [AppliedSnippetRule]
}
