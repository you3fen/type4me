import Foundation
import Type4MeIntelliSenseCore

/// Counts terms the user corrected by hand (`vocabulary-learning.json`). A
/// promoted spoken term is appended to the hotwords; a promoted written form
/// (e.g. "A\") becomes a global replacement rule from its repeated wrong form.
actor VocabularyLearningStore {
    static let shared = VocabularyLearningStore()

    private let fileURL: URL
    private let loadVocabulary: @Sendable () -> [String]
    private let loadTriggers: @Sendable () -> [String]
    private let addHotword: @Sendable (String) async throws -> Void
    private let addReplacement: @Sendable (String, String) async throws -> Void

    init(
        fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppDataLocation.profileDirectoryName)
            .appendingPathComponent("vocabulary-learning.json"),
        loadVocabulary: @escaping @Sendable () -> [String] = { HotwordStorage.load() },
        loadTriggers: @escaping @Sendable () -> [String] = { SnippetStorage.load().map(\.trigger) },
        addHotword: @escaping @Sendable (String) async throws -> Void = { term in
            try await MainActor.run {
                var words = HotwordStorage.load()
                guard !words.contains(where: {
                    VocabularyTermIdentity.triggerKey($0) == VocabularyTermIdentity.triggerKey(term)
                }) else { return }
                words.append(term)
                try HotwordStorage.saveOrThrow(words)
            }
        },
        addReplacement: @escaping @Sendable (String, String) async throws -> Void = { trigger, value in
            try await MainActor.run {
                var rules = SnippetStorage.load()
                guard !rules.contains(where: {
                    VocabularyTermIdentity.triggerKey($0.trigger) == VocabularyTermIdentity.triggerKey(trigger)
                }) else { return }
                rules.append((trigger: trigger, value: value))
                try SnippetStorage.saveOrThrow(rules)
            }
        }
    ) {
        self.fileURL = fileURL
        self.loadVocabulary = loadVocabulary
        self.loadTriggers = loadTriggers
        self.addHotword = addHotword
        self.addReplacement = addReplacement
    }

    /// Returns what was added to the hotwords or replacement rules, if anything.
    @discardableResult
    func record(original: String, edited: String) async -> VocabularyEditLearner.Promotion? {
        guard let correction = VocabularyEditLearner.correction(original: original, edited: edited),
              !IntelliSenseSensitiveTextScanner.containsSensitiveContent(correction.term)
        else { return nil }
        var state = load()
        let promoted = VocabularyEditLearner.record(
            correction, in: &state, knownVocabulary: loadVocabulary(), knownTriggers: loadTriggers()
        )
        do {
            switch promoted {
            case .hotword(let term): try await addHotword(term)
            case .replacement(let trigger, let value): try await addReplacement(trigger, value)
            case nil: break
            }
        } catch {
            DebugFileLogger.log("vocabulary learning save failed kind=\(correction.kind.rawValue)")
            return nil
        }
        save(state)
        DebugFileLogger.log("vocabulary learning recorded kind=\(correction.kind.rawValue) promoted=\(promoted != nil) tracked=\(state.terms.count)")
        return promoted
    }

    func trackedState() -> VocabularyEditLearner.State { load() }

    private func load() -> VocabularyEditLearner.State {
        guard let data = try? Data(contentsOf: fileURL) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(VocabularyEditLearner.State.self, from: data)) ?? .init()
    }

    private func save(_ state: VocabularyEditLearner.State) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
