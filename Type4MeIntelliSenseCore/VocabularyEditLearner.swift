import Foundation

/// Learns vocabulary from the user's own corrections of injected text.
///
/// One edit is weak evidence (it may be a wording change or a typo), so a term
/// is only promoted after the user has typed the same corrected term
/// `promotionThreshold` times. Everything here is pure; storage and the
/// hotword write live in the app target.
public enum VocabularyEditLearner {
    public static let promotionThreshold = 2
    public static let maximumTrackedTerms = 200

    public struct Correction: Equatable, Sendable {
        public let wrong: String
        public let term: String
    }

    /// The single corrected term in `edited`, or nil when the edit is not one
    /// contiguous term replacement.
    public static func correction(original: String, edited: String) -> Correction? {
        let old = tokens(original), new = tokens(edited)
        guard old != new else { return nil }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let wrong = trimmed(old[prefix..<(old.count - suffix)].joined())
        let term = trimmed(new[prefix..<(new.count - suffix)].joined())
        guard !wrong.isEmpty, wrong.count <= 12, isLearnable(term),
              wrong.lowercased() != term.lowercased()
        else { return nil }
        // A misheard Chinese term is replaced by one of the same length
        // (身材有数 → 生财有术); a longer or shorter rewrite is wording.
        if wrong.allSatisfy(isHan), term.allSatisfy(isHan), wrong.count != term.count { return nil }
        return Correction(wrong: wrong, term: term)
    }

    /// Chinese terms of 2–8 characters, or a Latin-led term of 3–30 characters
    /// such as "Raycast", "Type4Me" or "Claude code". Single characters,
    /// numbers and mixed Chinese/Latin phrases are left alone.
    public static func isLearnable(_ term: String) -> Bool {
        guard !term.isEmpty, !term.contains(where: \.isNewline) else { return false }
        if term.allSatisfy(isHan) { return (2...8).contains(term.count) }
        guard (3...30).contains(term.count), let first = term.unicodeScalars.first,
              first.isASCII, CharacterSet.letters.contains(first) else { return false }
        return term.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " .-+#".unicodeScalars.contains($0))
        }
    }

    public struct TrackedTerm: Codable, Equatable, Sendable {
        public var term: String
        public var count: Int
        public var wrongForms: [String]
        public var lastSeen: Date
    }

    public struct State: Codable, Equatable, Sendable {
        public var version = 1
        public var terms: [String: TrackedTerm] = [:]
        public init() {}
    }

    /// Records one correction. Returns the term to promote when it reaches the
    /// threshold; the promoted term is removed from the tracked state.
    public static func record(
        _ correction: Correction, in state: inout State, knownVocabulary: [String], now: Date = Date()
    ) -> String? {
        let key = VocabularyTermIdentity.spellingKey(correction.term)
        guard !key.isEmpty,
              !knownVocabulary.contains(where: { VocabularyTermIdentity.spellingKey($0) == key })
        else { return nil }
        var tracked = state.terms[key] ?? TrackedTerm(term: correction.term, count: 0, wrongForms: [], lastSeen: now)
        tracked.term = correction.term
        tracked.count += 1
        tracked.lastSeen = now
        if !tracked.wrongForms.contains(correction.wrong) {
            tracked.wrongForms = Array((tracked.wrongForms + [correction.wrong]).suffix(5))
        }
        guard tracked.count < promotionThreshold else {
            state.terms[key] = nil
            return tracked.term
        }
        state.terms[key] = tracked
        if state.terms.count > maximumTrackedTerms,
           let oldest = state.terms.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
            state.terms[oldest] = nil
        }
        return nil
    }

    // MARK: - Tokens

    /// Latin letter/digit runs are one token; every other character is its own
    /// token, so Chinese edits are compared character by character.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var run = ""
        for character in text {
            if character.isASCII, character.isLetter || character.isNumber {
                run.append(character)
                continue
            }
            if !run.isEmpty { result.append(run); run = "" }
            result.append(String(character))
        }
        if !run.isEmpty { result.append(run) }
        return result
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            switch $0.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
            default: return false
            }
        }
    }
}
