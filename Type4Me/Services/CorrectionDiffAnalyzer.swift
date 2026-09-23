import AppKit
import ApplicationServices
import Foundation
import Type4MeIntelliSenseCore

enum CorrectionDiffRejection: String, Equatable, Sendable {
    case unchanged
    case invalidRange
    case noChangeInsideInjection
    case multipleChanges
    case pureInsertionOrDeletion
    case ambiguousCJKReplacement
    case invalidCandidate
    case lowAffinity
    case sensitiveContent
}

enum CorrectionDiffResult: Equatable, Sendable {
    case candidate(wrongText: String, correctedText: String)
    case rejected(CorrectionDiffRejection)
}

/// Pure, deterministic analysis of changes made after Type4Me injected text.
enum CorrectionDiffAnalyzer {
    private struct EditHunk {
        var oldStart: Int
        var oldEnd: Int
        var newStart: Int
        var newEnd: Int
    }

    static func analyze(
        baseline: String,
        injectedRange: NSRange,
        current: String
    ) -> CorrectionDiffResult {
        guard baseline != current else { return .rejected(.unchanged) }
        guard let baselineRange = Range(injectedRange, in: baseline) else {
            return .rejected(.invalidRange)
        }

        let old = Array(baseline)
        let new = Array(current)
        let injectionStart = baseline.distance(from: baseline.startIndex, to: baselineRange.lowerBound)
        let injectionEnd = baseline.distance(from: baseline.startIndex, to: baselineRange.upperBound)

        guard let hunks = editHunks(old: old, new: new) else {
            return .rejected(.multipleChanges)
        }

        let inside = hunks.filter { hunk in
            if hunk.oldStart == hunk.oldEnd {
                return hunk.oldStart > injectionStart && hunk.oldStart < injectionEnd
            }
            return hunk.oldStart < injectionEnd && hunk.oldEnd > injectionStart
        }
        guard !inside.isEmpty else { return .rejected(.noChangeInsideInjection) }
        guard var hunk = mergedLexicalHunk(inside, old: old, new: new) else {
            return .rejected(.multipleChanges)
        }

        if isSensitiveChange(in: baseline, characterRange: hunk.oldStart..<hunk.oldEnd)
            || isSensitiveChange(in: current, characterRange: hunk.newStart..<hunk.newEnd) {
            return .rejected(.sensitiveContent)
        }

        let rawRemoved = Array(old[hunk.oldStart..<hunk.oldEnd])
        let rawInserted = Array(new[hunk.newStart..<hunk.newEnd])
        if !rawRemoved.isEmpty,
           !rawInserted.isEmpty,
           !(rawRemoved + rawInserted).contains(where: isLearnableCharacter) {
            return .rejected(.invalidCandidate)
        }
        let isCJKReplacement = !rawRemoved.isEmpty
            && !rawInserted.isEmpty
            && rawRemoved.allSatisfy(isCJK)
            && rawInserted.allSatisfy(isCJK)
        let isMixedScriptReplacement = isCJKLatinReplacement(
            removed: rawRemoved,
            inserted: rawInserted
        )
        if isMixedScriptReplacement {
            let trimmedRemoved = trimmingBoundaryWhitespace(rawRemoved)
            let trimmedInserted = trimmingBoundaryWhitespace(rawInserted)
            let cjkLength = trimmedRemoved.allSatisfy(isCJK)
                ? trimmedRemoved.count
                : trimmedInserted.count
            let latinLength = trimmedRemoved.allSatisfy(isCJK)
                ? trimmedInserted.count
                : trimmedRemoved.count
            guard cjkLength >= 2, latinLength >= 2 else {
                return .rejected(.ambiguousCJKReplacement)
            }
        }

        // A multi-character Chinese replacement already carries a useful word
        // boundary. Expanding it with arbitrary neighboring Han characters is
        // what turned “加好 → 佳豪” into “人的加好程度 → 人的佳豪程度”.
        // A single-character Chinese diff has no reliable word boundary, so V1
        // skips it rather than learning a dangerously broad mapping.
        if isCJKReplacement {
            guard rawRemoved.count >= 2, rawInserted.count >= 2 else {
                return .rejected(.ambiguousCJKReplacement)
            }
        } else if rawRemoved.isEmpty || rawInserted.isEmpty {
            let changedCharacters = rawRemoved + rawInserted
            let neighbors = [
                adjacentCharacter(in: old, before: hunk.oldStart),
                adjacentCharacter(in: old, at: hunk.oldEnd),
                adjacentCharacter(in: new, before: hunk.newStart),
                adjacentCharacter(in: new, at: hunk.newEnd),
            ].compactMap { $0 }
            // A one-sided diff is valid only when it edits the interior or edge
            // of an existing Latin/technical token. Adding/removing a whole
            // word necessarily includes a hard boundary and stays rejected.
            let changesTokenInterior = !changedCharacters.isEmpty
                && changedCharacters.allSatisfy(isTechnicalTokenCharacter)
                && neighbors.contains(where: isLatinTokenCharacter)
            let mergesOrSplitsTechnicalToken = !changedCharacters.isEmpty
                && changedCharacters.allSatisfy(\.isWhitespace)
                && neighbors.filter(isLatinTokenCharacter).count >= 2
            guard changesTokenInterior || mergesOrSplitsTechnicalToken,
                  !neighbors.contains(where: isCJK)
            else { return .rejected(.pureInsertionOrDeletion) }
        }

        // A Han transliteration corrected to a Latin technical/name token (or
        // the reverse) already has a hard script boundary. Expanding through
        // Character.isLetter is unsafe because Swift correctly treats Han as
        // letters too, which previously turned “杰瑞 → Jerry” into a whole-
        // sentence replacement candidate.
        let shouldExpandContext = !isCJKReplacement && !isMixedScriptReplacement
        let contextLimit = shouldExpandContext ? 64 : 0

        var leftExpansion = 0
        while hunk.oldStart > injectionStart,
              hunk.newStart > 0,
              leftExpansion < contextLimit {
            let oldCharacter = old[hunk.oldStart - 1]
            let newCharacter = new[hunk.newStart - 1]
            guard oldCharacter == newCharacter,
                  shouldExpand(over: oldCharacter, cjkMode: false)
            else { break }
            hunk.oldStart -= 1
            hunk.newStart -= 1
            leftExpansion += 1
        }

        var rightExpansion = 0
        while hunk.oldEnd < injectionEnd,
              hunk.newEnd < new.count,
              rightExpansion < contextLimit {
            let oldCharacter = old[hunk.oldEnd]
            let newCharacter = new[hunk.newEnd]
            guard oldCharacter == newCharacter,
                  shouldExpand(over: oldCharacter, cjkMode: false)
            else { break }
            hunk.oldEnd += 1
            hunk.newEnd += 1
            rightExpansion += 1
        }

        let wrong = String(old[hunk.oldStart..<hunk.oldEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = String(new[hunk.newStart..<hunk.newEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidCandidate(wrong), isValidCandidate(corrected), wrong != corrected else {
            return .rejected(.invalidCandidate)
        }
        guard !isSensitive(wrong), !isSensitive(corrected) else {
            return .rejected(.sensitiveContent)
        }
        if isMixedScriptReplacement {
            let latinToken = wrong.contains(where: isLatinTokenCharacter) ? wrong : corrected
            guard TechnicalTokenBoundaryResolver.isSingleStableToken(latinToken) else {
                return .rejected(.invalidCandidate)
            }
        } else if wrong.contains(where: isLatinTokenCharacter)
            || corrected.contains(where: isLatinTokenCharacter) {
            guard TechnicalTokenBoundaryResolver.isSingleStableToken(wrong),
                  TechnicalTokenBoundaryResolver.isSingleStableToken(corrected)
            else { return .rejected(.invalidCandidate) }
        }
        // Edit distance is not meaningful across writing systems: every
        // character in “杰瑞 → Jerry” differs even though it is a compact
        // lexical correction. ImmediateCorrectionAnalyzer separately verifies
        // the Han token boundary with the hybrid segmenter.
        if !isMixedScriptReplacement {
            let maximumLength = max(wrong.count, corrected.count)
            let maximumDistance = max(3, Int(ceil(Double(maximumLength) * 0.4)))
            guard editDistance(wrong, corrected) <= maximumDistance else {
                return .rejected(.invalidCandidate)
            }
        }
        return .candidate(wrongText: wrong, correctedText: corrected)
    }

    private static func mergedLexicalHunk(
        _ hunks: [EditHunk],
        old: [Character],
        new: [Character]
    ) -> EditHunk? {
        guard var merged = hunks.first else { return nil }
        for next in hunks.dropFirst() {
            let oldGap = next.oldStart >= merged.oldEnd
                ? Array(old[merged.oldEnd..<next.oldStart])
                : []
            let newGap = next.newStart >= merged.newEnd
                ? Array(new[merged.newEnd..<next.newStart])
                : []
            let gapIsWithinOneLexicalUnit = oldGap.count <= 4
                && newGap.count <= 4
                && oldGap.allSatisfy(isLearnableCharacter)
                && newGap.allSatisfy(isLearnableCharacter)
            guard gapIsWithinOneLexicalUnit else { return nil }
            merged.oldEnd = max(merged.oldEnd, next.oldEnd)
            merged.newEnd = max(merged.newEnd, next.newEnd)
        }
        return merged
    }

    private static func editHunks(old: [Character], new: [Character]) -> [EditHunk]? {
        let difference = new.difference(from: old)
        let removals = Set(difference.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else { return nil }
            return offset
        })
        let insertions = Set(difference.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })

        var oldIndex = 0
        var newIndex = 0
        var hunks: [EditHunk] = []
        var active: EditHunk?

        func flush() {
            if let active {
                hunks.append(active)
            }
            active = nil
        }

        while oldIndex < old.count || newIndex < new.count {
            var edited = false
            if newIndex < new.count, insertions.contains(newIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex, oldEnd: oldIndex,
                        newStart: newIndex, newEnd: newIndex
                    )
                }
                active?.newEnd = newIndex + 1
                newIndex += 1
                edited = true
            }
            if oldIndex < old.count, removals.contains(oldIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex, oldEnd: oldIndex,
                        newStart: newIndex, newEnd: newIndex
                    )
                }
                active?.oldEnd = oldIndex + 1
                oldIndex += 1
                edited = true
            }
            if edited { continue }

            guard oldIndex < old.count, newIndex < new.count, old[oldIndex] == new[newIndex] else {
                return nil
            }
            flush()
            oldIndex += 1
            newIndex += 1
        }
        flush()
        return hunks
    }

    private static func adjacentCharacter(in characters: [Character], before index: Int) -> Character? {
        guard index > 0, index <= characters.count else { return nil }
        return characters[index - 1]
    }

    private static func adjacentCharacter(in characters: [Character], at index: Int) -> Character? {
        guard index >= 0, index < characters.count else { return nil }
        return characters[index]
    }

    private static func shouldExpand(over character: Character, cjkMode: Bool) -> Bool {
        if cjkMode { return isCJK(character) }
        return isLatinTokenCharacter(character) || character == "_"
    }

    private static func isLearnableCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || isCJK(character)
    }

    private static func isTechnicalTokenCharacter(_ character: Character) -> Bool {
        isLatinTokenCharacter(character) || ".-_+#".contains(character)
    }

    private static func isLatinTokenCharacter(_ character: Character) -> Bool {
        character.isNumber || character.unicodeScalars.allSatisfy { scalar in
            scalar.value < 128 && CharacterSet.letters.contains(scalar)
        }
    }

    private static func isCJKLatinReplacement(
        removed: [Character],
        inserted: [Character]
    ) -> Bool {
        let removed = trimmingBoundaryWhitespace(removed)
        let inserted = trimmingBoundaryWhitespace(inserted)
        guard !removed.isEmpty, !inserted.isEmpty else { return false }
        let removedIsCJK = removed.allSatisfy(isCJK)
        let insertedIsCJK = inserted.allSatisfy(isCJK)
        let removedIsLatin = isStableLatinTechnicalToken(removed)
        let insertedIsLatin = isStableLatinTechnicalToken(inserted)
        return (removedIsCJK && insertedIsLatin)
            || (removedIsLatin && insertedIsCJK)
    }

    private static func isStableLatinTechnicalToken(_ characters: [Character]) -> Bool {
        let text = String(characters)
        return TechnicalTokenBoundaryResolver.isSingleStableToken(text)
            && characters.contains(where: isLatinTokenCharacter)
    }

    /// Diff hunks include a separator typed immediately beside a replacement.
    /// It establishes neither side's word identity, so inspect it only for
    /// classification and keep the original hunk indices for all extraction.
    private static func trimmingBoundaryWhitespace(_ characters: [Character]) -> [Character] {
        guard let first = characters.firstIndex(where: { !$0.isWhitespace }),
              let last = characters.lastIndex(where: { !$0.isWhitespace })
        else { return [] }
        return Array(characters[first...last])
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidCandidate(_ text: String) -> Bool {
        guard !text.contains("\n"), !text.contains("\r") else { return false }
        guard (2...64).contains(text.count) else { return false }
        guard text.split(whereSeparator: { $0.isWhitespace }).count <= 5 else { return false }
        return text.contains(where: isLearnableCharacter)
    }

    private static func isSensitive(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("www.") { return true }
        if matches(#"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#, in: text) { return true }
        if matches(#"(?:\d[\s-]?){7,}"#, in: text) { return true }
        if matches(#"\b(?=[A-Za-z0-9_-]{20,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#, in: text) {
            return true
        }
        return false
    }

    private static func isSensitiveChange(in text: String, characterRange: Range<Int>) -> Bool {
        let characters = Array(text)
        guard characterRange.lowerBound >= 0,
              characterRange.upperBound <= characters.count
        else { return true }
        let lowerIndex = text.index(text.startIndex, offsetBy: characterRange.lowerBound)
        let upperIndex = text.index(text.startIndex, offsetBy: characterRange.upperBound)
        let changedRange = NSRange(lowerIndex..<upperIndex, in: text)
        let patterns = [
            #"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"(?:https?://|www\.)\S+"#,
            #"(?:\d[\s-]?){7,}"#,
            #"\b(?=[A-Za-z0-9_-]{20,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: fullRange) {
                if changedRange.length == 0 {
                    if changedRange.location >= match.range.location,
                       changedRange.location <= NSMaxRange(match.range) {
                        return true
                    }
                } else if NSIntersectionRange(changedRange, match.range).length > 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.precomposedStringWithCanonicalMapping)
        let right = Array(rhs.precomposedStringWithCanonicalMapping)
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex]
                    + (leftCharacter == rightCharacter ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
            }
            previous = current
        }
        return previous[right.count]
    }
}
