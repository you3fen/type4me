import Foundation
import NaturalLanguage

/// Finds places where the ASR likely misheard a Chinese vocabulary term because of
/// accent: the pinyin of a same-length window equals the term's pinyin once
/// an/ang, en/eng, in/ing finals, z/zh, c/ch, s/sh initials and n/l are folded.
///
/// Only terms of three or more characters are matched, only on windows that
/// start and end on word boundaries ("模型吗" never yields "型吗"), and never when
/// the window is itself a single dictionary word. Two-character homophones such
/// as "会花" / "会话" are real words too often to rewrite, and hinting them to the
/// LLM made it rewrite "会花多少钱".
public enum PhoneticVocabularyMatcher {
    public struct Match: Sendable, Equatable {
        public let window: String
        public let term: String
        /// Character offsets into the input text.
        public let range: Range<Int>
    }

    public static let minimumTermLength = 3

    public static func matches(in text: String, vocabulary: [String]) -> [Match] {
        let terms = candidateTerms(vocabulary)
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        let chars = Array(text)
        let keys = chars.map { isHan($0) ? syllable($0).map(fold) : nil }
        let tokens = tokenRanges(text)
        let starts = Set(tokens.map(\.lowerBound)), ends = Set(tokens.map(\.upperBound))
        let singleWords = Set(tokens.map { "\($0.lowerBound):\($0.upperBound)" })

        var result: [Match] = []
        var claimed = IndexSet()
        // Longer terms first so "阶跃星辰" wins over a shorter overlapping term.
        for (term, termKey) in terms.sorted(by: { $0.term.count > $1.term.count }) {
            let n = termKey.count
            guard n >= minimumTermLength, chars.count >= n else { continue }
            for i in 0...(chars.count - n) {
                let range = i..<(i + n)
                guard starts.contains(i), ends.contains(i + n),
                      !claimed.contains(integersIn: range) else { continue }
                var equal = true
                for (offset, expected) in termKey.enumerated() where keys[i + offset] != expected {
                    equal = false
                    break
                }
                guard equal else { continue }
                let window = String(chars[range])
                guard window != term, !singleWords.contains("\(i):\(i + n)") else { continue }
                result.append(Match(window: window, term: term, range: range))
                claimed.insert(integersIn: range)
            }
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Returns the rewritten text and the distinct window → term pairs that
    /// fired, in text order.
    public static func applyReplacements(
        to text: String, vocabulary: [String]
    ) -> (text: String, applied: [(window: String, term: String)]) {
        let replacements = matches(in: text, vocabulary: vocabulary)
        guard !replacements.isEmpty else { return (text, []) }
        var chars = Array(text)
        for match in replacements.reversed() {
            chars.replaceSubrange(match.range, with: Array(match.term))
        }
        var applied: [(window: String, term: String)] = []
        var seen = Set<String>()
        for match in replacements where seen.insert(match.window + "\u{1F}" + match.term).inserted {
            applied.append((match.window, match.term))
        }
        return (String(chars), applied)
    }

    // MARK: - Pinyin

    static func fold(_ syllable: String) -> String {
        var s = syllable
        for (retroflex, flat) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where s.hasPrefix(retroflex) {
            s = flat + s.dropFirst(retroflex.count)
            break
        }
        if s.hasPrefix("l") { s = "n" + s.dropFirst() }
        for (back, front) in [("ang", "an"), ("eng", "en"), ("ing", "in")] where s.hasSuffix(back) {
            s = String(s.dropLast(back.count)) + front
            break
        }
        return s
    }

    static func syllable(_ character: Character) -> String? {
        guard let latin = String(character).applyingTransform(.mandarinToLatin, reverse: false),
              let plain = latin.applyingTransform(.stripCombiningMarks, reverse: false)?.lowercased(),
              !plain.isEmpty, plain.utf8.allSatisfy({ (97...122).contains($0) })
        else { return nil }
        return plain
    }

    private static func candidateTerms(_ vocabulary: [String]) -> [(term: String, key: [String])] {
        var seen = Set<String>()
        return vocabulary.compactMap { raw in
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2, term.allSatisfy(isHan), seen.insert(term).inserted else { return nil }
            var key: [String] = []
            for character in term {
                guard let value = syllable(character) else { return nil }
                key.append(fold(value))
            }
            return (term, key)
        }
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            switch $0.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
            default: return false
            }
        }
    }

    private static func tokenRanges(_ text: String) -> [Range<Int>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        var ranges: [Range<Int>] = []
        var cursor = text.startIndex
        var offset = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            offset += text.distance(from: cursor, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            ranges.append(offset..<(offset + length))
            offset += length
            cursor = range.upperBound
            return true
        }
        return ranges
    }
}
