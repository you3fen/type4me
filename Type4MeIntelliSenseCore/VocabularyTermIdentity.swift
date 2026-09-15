import Foundation

/// One identity for whitespace/case-insensitive triggers, not for display text.
/// Canonical spellings intentionally retain internal spaces and punctuation.
public enum VocabularyTermIdentity {
    public static func triggerKey(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }

    public static func spellingKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func pattern(_ term: String, protectsIdentifiers: Bool = true) -> String {
        let key = triggerKey(term)
        guard !key.isEmpty else { return "(?!)" }
        let core = key.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s*"#)
        let boundary = protectsIdentifiers ? "A-Za-z0-9_" : "A-Za-z0-9"
        return "(?<![\(boundary)])" + core + "(?![\(boundary)])"
    }

    public static func occurs(_ term: String, in text: String) -> Bool {
        text.range(of: pattern(term), options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// These are literal spans, not a general-purpose semantic or PII detector.
/// Used by the existing output validator; it never edits the emitted text.
public enum VocabularyLiteralProtection {
    public static func spans(in text: String) -> [String] {
        let patterns = [
            #"`[^`\n]+`|\"[^\"\n]+\"|“[^”\n]+”|「[^」\n]+」|『[^』\n]+』|(?<![A-Za-z])'[^'\n]+'(?![A-Za-z])"#,
            #"(?<![A-Za-z0-9_])[A-Za-z_$][A-Za-z0-9_$]*_[A-Za-z0-9_$]+(?![A-Za-z0-9_])"#,
        ]
        return patterns.enumerated().flatMap { index, pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range, in: text).map { range in
                    let literal = String(text[range])
                    if index == 0 {
                        let kind = literal.first == "`" ? "code:" : "quote:"
                        return kind + literal.dropFirst().dropLast()
                    }
                    return "identifier:" + literal
                }
            }
        }
    }

    public static func preserved(input: String, candidate: String) -> Bool {
        // Do not loosen quote/identifier protection merely because a personal
        // dictionary contains a preferred spelling. Repeated literals count too.
        let expected = Dictionary(grouping: spans(in: input), by: { $0 })
        let actual = Dictionary(grouping: spans(in: candidate), by: { $0 })
        return expected.allSatisfy { (actual[$0.key]?.count ?? 0) >= $0.value.count }
    }

    public static func deletesOnlyNegation(input: String, candidate: String) -> Bool {
        guard !CorrectionIntentAnalysis.analyze(input).containsExplicitCorrection else { return false }
        func lexical(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let pattern = #"(?i)没有|不是|并非|不能|无法|尚未|不|没|未|\bnot\b|\bno\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let target = lexical(candidate)
        guard target != lexical(input) else { return false }
        return regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).contains { match in
            guard let range = Range(match.range, in: input) else { return false }
            var without = input
            without.removeSubrange(range)
            return lexical(without) == target
        }
    }
}
