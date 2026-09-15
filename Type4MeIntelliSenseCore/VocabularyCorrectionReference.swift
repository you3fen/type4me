import Foundation

/// An explicitly confirmed, app-scoped spelling observation. It is reference
/// data for the existing polishing request, never a SnippetStorage rule.
public struct VocabularyCorrectionReference: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let wrongText: String
    public let correctedText: String
    public let bundleIdentifier: String
    public let sourceRecordID: String
    public let confirmedAt: Date

    public init(id: String = UUID().uuidString, wrongText: String, correctedText: String,
                bundleIdentifier: String, sourceRecordID: String, confirmedAt: Date = Date()) {
        self.id = id
        self.wrongText = wrongText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.correctedText = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleIdentifier = bundleIdentifier
        self.sourceRecordID = sourceRecordID
        self.confirmedAt = confirmedAt
    }

    public var comparisonKey: String {
        [bundleIdentifier, wrongText, correctedText].map { $0.lowercased() }.joined(separator: "\u{0}")
    }

    public var isValid: Bool {
        !bundleIdentifier.isEmpty && wrongText != correctedText
            && Self.isSafeTerm(wrongText) && Self.isSafeTerm(correctedText)
    }

    private static func isSafeTerm(_ text: String) -> Bool {
        guard (2...64).contains(text.count), text.contains(where: \.isLetter),
              text.split(whereSeparator: \.isWhitespace).count <= 5,
              !text.contains(where: \.isNewline),
              !IntelliSenseSensitiveTextScanner.containsSensitiveContent(text)
        else { return false }
        // Keep paths, credentials, quoted instructions and bare versions out of
        // the spelling-reference channel. This is not a general PII detector.
        return text.range(of: #"[/\\@`<>\"“”「」『』:=\n\r]|(?i)^v?\d+(?:\.\d+)*$"#, options: .regularExpression) == nil
    }
}

public enum VocabularyCorrectionPolicy {
    /// Bounded, app-local, unambiguous observations whose source is present in
    /// this request. No retrieval from unrelated apps or entire history.
    public static func select(_ references: [VocabularyCorrectionReference],
                              input: String, context: IntelliSenseContextSnapshot?) -> [VocabularyCorrectionReference] {
        guard let context, let bundle = context.bundleIdentifier,
              context.availability != .blacklisted, context.availability != .sensitive
        else { return [] }
        let scoped = references.filter { $0.isValid && $0.bundleIdentifier == bundle }
        let groups = Dictionary(grouping: scoped, by: { $0.wrongText.lowercased() })
        var result: [VocabularyCorrectionReference] = []
        var seen = Set<String>()
        var characters = 0
        for ref in scoped.sorted(by: { $0.confirmedAt > $1.confirmedAt }) {
            guard result.count < 12, seen.insert(ref.comparisonKey).inserted,
                  Set((groups[ref.wrongText.lowercased()] ?? []).map { $0.correctedText.lowercased() }).count == 1,
                  !input.localizedCaseInsensitiveContains(ref.correctedText),
                  let source = uniqueRange(of: ref.wrongText, in: input),
                  !isProtected(source, in: input)
            else { continue }
            let cost = ref.wrongText.count + ref.correctedText.count
            guard characters + cost <= 800 else { continue }
            result.append(ref)
            characters += cost
        }
        return result
    }

    /// Normalize ONLY evidenced local edits when evaluating the candidate.
    /// This never edits the emitted text. The original input remains the
    /// rejection fallback; the rest of the existing validator stays enabled.
    public static func validationInput(_ input: String, candidate: String,
                                       references: [VocabularyCorrectionReference],
                                       context: IntelliSenseContextSnapshot?) -> String {
        var edits: [(Range<String.Index>, String)] = []
        for ref in select(references, input: input, context: context) {
            guard let oldRange = uniqueRange(of: ref.wrongText, in: input),
                  let newRange = uniqueRange(of: ref.correctedText, in: candidate),
                  !candidate.localizedCaseInsensitiveContains(ref.wrongText),
                  !isProtected(newRange, in: candidate),
                  anchorsAgree(input, range: oldRange, candidate, other: newRange),
                  !edits.contains(where: { $0.0.overlaps(oldRange) })
            else { continue }
            edits.append((oldRange, String(candidate[newRange])))
        }
        var normalized = input
        for (range, spelling) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            normalized.replaceSubrange(range, with: spelling)
        }
        return normalized
    }

    private static func uniqueRange(of term: String, in text: String) -> Range<String.Index>? {
        let chars = term.filter { !$0.isWhitespace }
        let core = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s*"#)
        // Underscores belong to identifiers; Han/Latin transitions are valid
        // dictation boundaries. File/path/quote protection is checked separately.
        guard let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + core + "(?![A-Za-z0-9_])", options: [.caseInsensitive]) else { return nil }
        let hits = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard hits.count == 1 else { return nil }
        return Range(hits[0].range, in: text)
    }

    private static func anchorsAgree(_ text: String, range: Range<String.Index>,
                                     _ output: String, other: Range<String.Index>) -> Bool {
        func normalized(_ value: Substring) -> [Character] {
            Array(value.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        // Conservatively require the nearest lexical context on BOTH sides.
        // Large simultaneous rewrites may abstain rather than broadly whitelist
        // every digit-bearing brand in a personal dictionary.
        let left = normalized(text[..<range.lowerBound]).suffix(8)
        let right = normalized(text[range.upperBound...]).prefix(8)
        return Array(left) == Array(normalized(output[..<other.lowerBound]).suffix(8))
            && Array(right) == Array(normalized(output[other.upperBound...]).prefix(8))
    }

    private static func isProtected(_ range: Range<String.Index>, in text: String) -> Bool {
        let patterns = [
            #"`[^`]*`|\"[^\"]*\"|“[^”]*”|「[^」]*」|『[^』]*』|'[^']*'"#,
            #"(?i)(?:https?://|www\.)[^\s]+|[^\s]*[/\\@_][^\s]*"#,
            #"[A-Za-z0-9_-]+\.[A-Za-z][A-Za-z0-9._-]*"#,
        ]
        let target = NSRange(range, in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains(where: {
                NSIntersectionRange($0.range, target).length > 0
            }) { return true }
        }
        // An explicit preservation/contrast instruction outweighs a spelling
        // memory. This narrow safeguard does not claim full semantic certainty.
        let clause = String(text).lowercased()
        return ["请保留", "不要改", "别改", "原文", "不是", "并非", "不是指", "keep ", "do not change", "don't change", "not "].contains(where: clause.contains)
    }
}
