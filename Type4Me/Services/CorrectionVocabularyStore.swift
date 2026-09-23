import Foundation
import Type4MeIntelliSenseCore

struct CorrectionCandidate: Equatable, Sendable {
    let wrongText: String
    let correctedText: String
    let sourceRecordID: String
    let bundleIdentifier: String
    let learningScope: CorrectionLearningScope

    init(
        wrongText: String,
        correctedText: String,
        sourceRecordID: String,
        bundleIdentifier: String,
        learningScope: CorrectionLearningScope = .hotwordOnly
    ) {
        self.wrongText = wrongText
        self.correctedText = correctedText
        self.sourceRecordID = sourceRecordID
        self.bundleIdentifier = bundleIdentifier
        self.learningScope = learningScope
    }
}

enum CorrectionLearningScope: String, Equatable, Hashable, Sendable {
    /// Add the correct spelling to the hotwords.
    case hotwordOnly
    /// Also add an explicit global replacement rule wrong → correct.
    case hotwordAndMapping
}

struct CorrectionMapping: Equatable, Sendable {
    let trigger: String
    let replacement: String
}

protocol CorrectionVocabularyPersisting {
    func loadHotwords() -> [String]
    func loadMappings() -> [CorrectionMapping]
    func saveHotwords(_ words: [String]) throws
    func saveMappings(_ mappings: [CorrectionMapping]) throws
    func didCommitHotwords()
}

extension CorrectionVocabularyPersisting {
    func didCommitHotwords() {}
}

enum CorrectionLearningOutcome: Equatable { case saved, alreadyKnown }

enum CorrectionVocabularyError: Error {
    case invalidTerm
    case conflictingBatch
    case rollbackFailed
}

/// Writes a user-confirmed correction from the history sheet: the correct
/// spelling becomes a hotword, and only the explicit `hotwordAndMapping`
/// choice adds a replacement rule. I/O errors never become success.
struct CorrectionLearningStore {
    let persistence: any CorrectionVocabularyPersisting

    init(persistence: any CorrectionVocabularyPersisting = Type4MeCorrectionVocabularyPersistence()) {
        self.persistence = persistence
    }

    @discardableResult
    func learn(_ candidate: CorrectionCandidate) throws -> CorrectionLearningOutcome {
        try learn([candidate])
    }

    @discardableResult
    func learn(_ candidates: [CorrectionCandidate], hotwords: [String] = []) throws -> CorrectionLearningOutcome {
        let oldWords = persistence.loadHotwords()
        var words = oldWords
        let usesMappings = candidates.contains { $0.learningScope == .hotwordAndMapping }
        let oldMappings = usesMappings ? persistence.loadMappings() : []
        var mappings = oldMappings
        var batchMappings: [String: String] = [:]

        for raw in hotwords + candidates.map(\.correctedText) {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !word.contains(where: \.isNewline) else { throw CorrectionVocabularyError.invalidTerm }
            if !words.contains(where: { VocabularyTermIdentity.spellingKey($0) == VocabularyTermIdentity.spellingKey(word) }) {
                words.append(word)
            }
        }
        for candidate in candidates where candidate.learningScope == .hotwordAndMapping {
            let key = VocabularyTermIdentity.triggerKey(candidate.wrongText)
            guard !key.isEmpty else { throw CorrectionVocabularyError.invalidTerm }
            let spelling = candidate.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let previous = batchMappings[key], previous != spelling { throw CorrectionVocabularyError.conflictingBatch }
            batchMappings[key] = spelling
            let first = mappings.firstIndex { VocabularyTermIdentity.triggerKey($0.trigger) == key }
            // Explicitly replacing this trigger also removes its equivalent
            // case/space duplicates. Unrelated and App rules stay untouched.
            mappings.removeAll { VocabularyTermIdentity.triggerKey($0.trigger) == key }
            mappings.insert(CorrectionMapping(trigger: candidate.wrongText, replacement: spelling),
                            at: min(first ?? mappings.count, mappings.count))
        }
        return try persist(oldWords: oldWords, words: words, oldMappings: oldMappings, mappings: mappings)
    }

    private func persist(oldWords: [String], words: [String],
                         oldMappings: [CorrectionMapping], mappings: [CorrectionMapping]) throws -> CorrectionLearningOutcome {
        let wordsChanged = words != oldWords
        let mappingsChanged = mappings != oldMappings
        guard wordsChanged || mappingsChanged else { return .alreadyKnown }
        var wroteWords = false, wroteMappings = false
        do {
            if wordsChanged { wroteWords = true; try persistence.saveHotwords(words) }
            if mappingsChanged { wroteMappings = true; try persistence.saveMappings(mappings) }
        } catch {
            let originalError = error
            var rollbackFailed = false
            if wroteMappings { do { try persistence.saveMappings(oldMappings) } catch { rollbackFailed = true } }
            if wroteWords { do { try persistence.saveHotwords(oldWords) } catch { rollbackFailed = true } }
            if rollbackFailed { throw CorrectionVocabularyError.rollbackFailed }
            throw originalError
        }
        // Hotword side effects start only after all saves.
        if wordsChanged { persistence.didCommitHotwords() }
        return .saved
    }
}

struct Type4MeCorrectionVocabularyPersistence: CorrectionVocabularyPersisting {
    func didCommitHotwords() { HotwordStorage.notifyDidChange() }
    func loadHotwords() -> [String] { HotwordStorage.load() }
    func loadMappings() -> [CorrectionMapping] {
        SnippetStorage.load().map { CorrectionMapping(trigger: $0.trigger, replacement: $0.value) }
    }
    func saveHotwords(_ words: [String]) throws { try HotwordStorage.saveOrThrow(words, notify: false) }
    func saveMappings(_ mappings: [CorrectionMapping]) throws {
        try SnippetStorage.saveOrThrow(mappings.map { (trigger: $0.trigger, value: $0.replacement) })
    }
}
