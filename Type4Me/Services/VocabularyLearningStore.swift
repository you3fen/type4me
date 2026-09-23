import Foundation
import Type4MeIntelliSenseCore

/// Counts terms the user corrected by hand (`vocabulary-learning.json`) and
/// appends a term to the hotwords once `VocabularyEditLearner` promotes it.
actor VocabularyLearningStore {
    static let shared = VocabularyLearningStore()

    private let fileURL: URL
    private let loadVocabulary: @Sendable () -> [String]
    private let addHotword: @Sendable (String) async throws -> Void

    init(
        fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppDataLocation.profileDirectoryName)
            .appendingPathComponent("vocabulary-learning.json"),
        loadVocabulary: @escaping @Sendable () -> [String] = { HotwordStorage.load() },
        addHotword: @escaping @Sendable (String) async throws -> Void = { term in
            try await MainActor.run {
                var words = HotwordStorage.load()
                guard !words.contains(where: {
                    VocabularyTermIdentity.spellingKey($0) == VocabularyTermIdentity.spellingKey(term)
                }) else { return }
                words.append(term)
                try HotwordStorage.saveOrThrow(words)
            }
        }
    ) {
        self.fileURL = fileURL
        self.loadVocabulary = loadVocabulary
        self.addHotword = addHotword
    }

    /// Returns the term that was added to the hotwords, if any.
    @discardableResult
    func record(original: String, edited: String) async -> String? {
        guard let correction = VocabularyEditLearner.correction(original: original, edited: edited),
              !IntelliSenseSensitiveTextScanner.containsSensitiveContent(correction.term)
        else { return nil }
        var state = load()
        let promoted = VocabularyEditLearner.record(
            correction, in: &state, knownVocabulary: loadVocabulary()
        )
        if let promoted {
            do {
                try await addHotword(promoted)
            } catch {
                DebugFileLogger.log("vocabulary learning hotword save failed")
                return nil
            }
        }
        save(state)
        DebugFileLogger.log("vocabulary learning recorded promoted=\(promoted != nil) tracked=\(state.terms.count)")
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
