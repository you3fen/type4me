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
        learningScope: CorrectionLearningScope = .softReference
    ) {
        self.wrongText = wrongText
        self.correctedText = correctedText
        self.sourceRecordID = sourceRecordID
        self.bundleIdentifier = bundleIdentifier
        self.learningScope = learningScope
    }
}

enum CorrectionLearningScope: String, Equatable, Hashable, Sendable {
    /// Default: explicitly confirmed app-scoped evidence, not a forced rule.
    case softReference
    /// Explicit consent to reuse this spelling reference across Apps.
    case sharedReference
    /// Explicit opt-in only: the user requests an unconditional global rule.
    case hotwordAndMapping

    /// A user may confirm the preferred word without promoting an uncertain
    /// observed phrase into a global replacement rule.
    case hotwordOnly
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
    func loadReferences() throws -> [VocabularyCorrectionReference]
    func saveReferences(_ references: [VocabularyCorrectionReference]) throws
    func didCommitHotwords()
}

extension CorrectionVocabularyPersisting {
    func loadReferences() throws -> [VocabularyCorrectionReference] { throw CorrectionReferenceError.unsupportedPersistence }
    func saveReferences(_ references: [VocabularyCorrectionReference]) throws { throw CorrectionReferenceError.unsupportedPersistence }
    func didCommitHotwords() {}
}

enum CorrectionLearningOutcome: Equatable { case saved, alreadyKnown }

enum CorrectionVocabularyError: Error {
    case invalidTerm
    case conflictingBatch
    case rollbackFailed
}

/// The shared confirmation writer. It does not generate variants or reinterpret
/// existing snippets. References require explicit consent; forced rules require
/// the separate hotwordAndMapping choice. I/O errors never become success.
struct CorrectionLearningStore {
    let persistence: any CorrectionVocabularyPersisting

    init(persistence: any CorrectionVocabularyPersisting) {
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
        let usesReferences = candidates.contains { $0.learningScope == .softReference || $0.learningScope == .sharedReference }
        let usesMappings = candidates.contains { $0.learningScope == .hotwordAndMapping }
        let oldReferences = usesReferences ? try persistence.loadReferences() : []
        let oldMappings = usesMappings ? persistence.loadMappings() : []
        var references = oldReferences
        var mappings = oldMappings
        var batchMappings: [String: String] = [:]

        for raw in hotwords + candidates.map(\.correctedText) {
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, !word.contains(where: \.isNewline) else { throw CorrectionVocabularyError.invalidTerm }
            if !words.contains(where: { VocabularyTermIdentity.spellingKey($0) == VocabularyTermIdentity.spellingKey(word) }) {
                words.append(word)
            }
        }
        for candidate in candidates {
            switch candidate.learningScope {
            case .hotwordOnly:
                break
            case .softReference, .sharedReference:
                let reference = VocabularyCorrectionReference(
                    wrongText: candidate.wrongText, correctedText: candidate.correctedText,
                    bundleIdentifier: candidate.bundleIdentifier, sourceRecordID: candidate.sourceRecordID,
                    sharedAcrossApps: candidate.learningScope == .sharedReference ? true : nil
                )
                guard reference.isValid else { throw CorrectionReferenceError.invalidReference }
                if !references.contains(where: { $0.comparisonKey == reference.comparisonKey }) {
                    references.append(reference)
                }
            case .hotwordAndMapping:
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
        }
        return try persist(oldWords: oldWords, words: words,
                           oldReferences: oldReferences, references: references,
                           oldMappings: oldMappings, mappings: mappings)
    }

    /// One canonical rename updates existing reference targets too. Explicit
    /// snippets are deliberately independent: renaming a word is not consent to
    /// change a quick expansion. No wrong/right history is invented.
    @discardableResult
    func renameCanonical(_ old: String, to new: String) throws -> CorrectionLearningOutcome {
        let spelling = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spelling.isEmpty, !spelling.contains(where: \.isNewline) else { throw CorrectionVocabularyError.invalidTerm }
        let oldWords = persistence.loadHotwords()
        let oldReferences = try persistence.loadReferences()
        let key = VocabularyTermIdentity.spellingKey(old)
        var words = oldWords.map { VocabularyTermIdentity.spellingKey($0) == key ? spelling : $0 }
        if !words.contains(where: { VocabularyTermIdentity.spellingKey($0) == VocabularyTermIdentity.spellingKey(spelling) }) {
            words.append(spelling)
        }
        var seen = Set<String>()
        words = words.filter { seen.insert(VocabularyTermIdentity.spellingKey($0)).inserted }
        let references = oldReferences.map { reference in
            guard VocabularyTermIdentity.spellingKey(reference.correctedText) == key else { return reference }
            return VocabularyCorrectionReference(id: reference.id, wrongText: reference.wrongText,
                correctedText: spelling, bundleIdentifier: reference.bundleIdentifier,
                sourceRecordID: reference.sourceRecordID, confirmedAt: reference.confirmedAt,
                sharedAcrossApps: reference.sharedAcrossApps)
        }
        guard references.allSatisfy(\.isValid) else { throw CorrectionReferenceError.invalidReference }
        return try persist(oldWords: oldWords, words: words,
                           oldReferences: oldReferences, references: references,
                           oldMappings: [], mappings: [])
    }

    /// Called only by an explicit canonical-name deletion action. Quick
    /// expansions are independent user commands and are never removed here.
    @discardableResult
    func removeCanonical(_ spelling: String) throws -> CorrectionLearningOutcome {
        let oldWords = persistence.loadHotwords()
        let oldReferences = try persistence.loadReferences()
        let key = VocabularyTermIdentity.spellingKey(spelling)
        let words = oldWords.filter { VocabularyTermIdentity.spellingKey($0) != key }
        let references = oldReferences.filter { VocabularyTermIdentity.spellingKey($0.correctedText) != key }
        return try persist(oldWords: oldWords, words: words,
                           oldReferences: oldReferences, references: references,
                           oldMappings: [], mappings: [])
    }

    private func persist(oldWords: [String], words: [String],
                         oldReferences: [VocabularyCorrectionReference], references: [VocabularyCorrectionReference],
                         oldMappings: [CorrectionMapping], mappings: [CorrectionMapping]) throws -> CorrectionLearningOutcome {
        let wordsChanged = words != oldWords
        let referencesChanged = references != oldReferences
        let mappingsChanged = mappings != oldMappings
        guard wordsChanged || referencesChanged || mappingsChanged else { return .alreadyKnown }
        var wroteWords = false, wroteReferences = false, wroteMappings = false
        do {
            if wordsChanged { wroteWords = true; try persistence.saveHotwords(words) }
            if referencesChanged { wroteReferences = true; try persistence.saveReferences(references) }
            if mappingsChanged { wroteMappings = true; try persistence.saveMappings(mappings) }
        } catch {
            let originalError = error
            var rollbackFailed = false
            if wroteMappings { do { try persistence.saveMappings(oldMappings) } catch { rollbackFailed = true } }
            if wroteReferences { do { try persistence.saveReferences(oldReferences) } catch { rollbackFailed = true } }
            if wroteWords { do { try persistence.saveHotwords(oldWords) } catch { rollbackFailed = true } }
            if rollbackFailed { throw CorrectionVocabularyError.rollbackFailed }
            throw originalError
        }
        // Cloud sync and other hotword side effects start only after all saves.
        if wordsChanged { persistence.didCommitHotwords() }
        return .saved
    }
}
