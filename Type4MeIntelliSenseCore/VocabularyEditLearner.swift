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

    public enum Kind: String, Codable, Sendable {
        /// A spoken term the ASR can be biased toward (Raycast, 生财有术).
        case hotword
        /// A written form nobody pronounces as spelled (A\): hotwords cannot
        /// help, so the repeated wrong form becomes a replacement rule.
        case replacement
    }

    public struct Correction: Equatable, Sendable {
        public let wrong: String
        public let term: String
        public var kind: Kind = .hotword
    }

    public enum Promotion: Equatable, Sendable {
        case hotword(String)
        case replacement(trigger: String, value: String)
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
        var lower = prefix, oldUpper = old.count - suffix, newUpper = new.count - suffix
        // A symbol-only change such as "A 处" → "A\" belongs to the adjacent
        // Latin token; widen both sides over it so the whole written form is kept.
        if !new[lower..<newUpper].joined().contains(where: isWordCharacter) {
            if lower > 0, isLatinRun(new[lower - 1]) { lower -= 1 }
            if newUpper < new.count, isLatinRun(new[newUpper]) { newUpper += 1; oldUpper += 1 }
        }
        let rawWrong = old[lower..<oldUpper].joined(), rawTerm = new[lower..<newUpper].joined()

        let wrong = trimmed(rawWrong), term = trimmed(rawTerm)
        if !wrong.isEmpty, wrong.count <= 12, isLearnable(term),
           wrong.lowercased() != term.lowercased(),
           // A misheard Chinese term is replaced by one of the same length
           // (身材有数 → 生财有术); a longer or shorter rewrite is wording.
           !(wrong.allSatisfy(isHan) && term.allSatisfy(isHan) && wrong.count != term.count) {
            return Correction(wrong: wrong, term: term)
        }

        let ruleWrong = rawWrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let ruleTerm = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWrittenForm(ruleTerm), (2...12).contains(ruleWrong.count),
              ruleWrong.contains(where: isWordCharacter), !ruleWrong.contains(where: \.isNewline),
              !ruleWrong.contains(where: isSymbol)
        else { return nil }
        return Correction(wrong: ruleWrong, term: ruleTerm, kind: .replacement)
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

    /// A short written form with a letter and a symbol, e.g. "A\" or "C++".
    static func isWrittenForm(_ term: String) -> Bool {
        (2...12).contains(term.count) && !term.contains(where: \.isNewline)
            && term.contains(where: isWordCharacter) && term.contains(where: isSymbol)
    }

    public struct TrackedTerm: Codable, Equatable, Sendable {
        public var term: String
        public var count: Int
        public var wrongForms: [String]
        public var lastSeen: Date
        public var kind: Kind? = nil
    }

    public struct State: Codable, Equatable, Sendable {
        public var version = 1
        public var terms: [String: TrackedTerm] = [:]
        public init() {}
    }

    /// Records one correction and returns what to add once it reaches the
    /// threshold; a promoted entry leaves the tracked state. Hotwords count
    /// the corrected term; replacement rules count the exact wrong form.
    public static func record(
        _ correction: Correction, in state: inout State, knownVocabulary: [String],
        knownTriggers: [String] = [], now: Date = Date()
    ) -> Promotion? {
        let key: String
        switch correction.kind {
        case .hotword:
            key = VocabularyTermIdentity.triggerKey(correction.term)
            guard !key.isEmpty,
                  !knownVocabulary.contains(where: { VocabularyTermIdentity.triggerKey($0) == key })
            else { return nil }
        case .replacement:
            let trigger = VocabularyTermIdentity.triggerKey(correction.wrong)
            guard !trigger.isEmpty,
                  !knownTriggers.contains(where: { VocabularyTermIdentity.triggerKey($0) == trigger })
            else { return nil }
            key = "rule:" + trigger + "\u{1F}" + correction.term
        }
        var tracked = state.terms[key]
            ?? TrackedTerm(term: correction.term, count: 0, wrongForms: [], lastSeen: now, kind: correction.kind)
        tracked.term = correction.term
        tracked.count += 1
        tracked.lastSeen = now
        if !tracked.wrongForms.contains(correction.wrong) {
            tracked.wrongForms = Array((tracked.wrongForms + [correction.wrong]).suffix(5))
        }
        guard tracked.count < promotionThreshold else {
            state.terms[key] = nil
            switch correction.kind {
            case .hotword: return .hotword(tracked.term)
            case .replacement: return .replacement(trigger: correction.wrong, value: tracked.term)
            }
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

    private static func isLatinRun(_ token: String) -> Bool {
        token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func isSymbol(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber && !character.isWhitespace
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
