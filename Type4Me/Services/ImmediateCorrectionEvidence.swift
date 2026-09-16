import Foundation

/// A bounded *suggestion* signal, not permission to rewrite future dictation.
/// Keep the strict/batch affinity evaluator unchanged. No general edit-distance
/// threshold, phonetic variant dictionary, network request or automatic save.
enum CorrectionSuggestionPhonetics {
    static func isPlausible(wrong: String, corrected: String) -> Bool {
        guard isCompactHanTerm(wrong), isCompactHanTerm(corrected),
              wrong.count == corrected.count, wrong != corrected,
              let lhs = syllables(wrong), let rhs = syllables(corrected),
              lhs.count == wrong.count, rhs.count == corrected.count
        else { return false }
        var confusions = 0
        for (left, right) in zip(lhs, rhs) where left != right {
            guard isAllowedConfusion(left, right) else { return false }
            confusions += 1
        }
        // At most one confused syllable in a 2–3 character term, two in a
        // longer term. Exact homophones cost zero, but still need confirmation.
        return confusions <= min(2, max(1, lhs.count / 2))
    }

    static func isCompactHanTerm(_ text: String) -> Bool {
        (2...8).contains(text.count) && text.unicodeScalars.allSatisfy {
            switch $0.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
            default: return false
            }
        }
    }

    private static func syllables(_ text: String) -> [String]? {
        guard let latin = text.applyingTransform(.mandarinToLatin, reverse: false),
              let unaccented = latin.applyingTransform(.stripCombiningMarks, reverse: false)
        else { return nil }
        let parts = unaccented.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (97...122).contains($0) } })
        else { return nil }
        return parts
    }

    private static func isAllowedConfusion(_ lhs: String, _ rhs: String) -> Bool {
        // n/l only in the initial; an/ang, en/eng, in/ing only in the final.
        // Do not erase every n/g/l or allow both errors within one syllable.
        if ((lhs.first == "n" && rhs.first == "l") || (lhs.first == "l" && rhs.first == "n")),
           lhs.dropFirst() == rhs.dropFirst() { return true }
        for (front, back) in [("an", "ang"), ("en", "eng"), ("in", "ing")] {
            if lhs.hasSuffix(front), rhs.hasSuffix(back),
               lhs.dropLast(front.count) == rhs.dropLast(back.count) { return true }
            if rhs.hasSuffix(front), lhs.hasSuffix(back),
               rhs.dropLast(front.count) == lhs.dropLast(back.count) { return true }
        }
        return false
    }
}

/// An observed boundary in the *original injected text*, in UTF-16 offsets.
/// A selection is evidence of the edited extent, not proof that it is a name.
struct CorrectionEditBoundary: Equatable, Sendable {
    enum Source: String, Sendable { case selection, deletion }
    let range: NSRange
    let source: Source

    func replacement(original: String, edited: String) -> (wrong: String, corrected: String)? {
        guard range.location >= 0, range.length >= 0,
              range.location <= original.utf16.count,
              range.length <= original.utf16.count - range.location,
              let oldRange = Range(range, in: original) else { return nil }
        let wrong = String(original[oldRange])
        guard CorrectionSuggestionPhonetics.isCompactHanTerm(wrong) else { return nil }
        let prefix = String(original[..<oldRange.lowerBound])
        let suffix = String(original[oldRange.upperBound...])
        guard edited.hasPrefix(prefix), edited.hasSuffix(suffix),
              edited.count >= prefix.count + suffix.count else { return nil }
        let start = edited.index(edited.startIndex, offsetBy: prefix.count)
        let end = edited.index(edited.endIndex, offsetBy: -suffix.count)
        let corrected = String(edited[start..<end])
        guard CorrectionSuggestionPhonetics.isCompactHanTerm(corrected),
              wrong != corrected else { return nil }
        return (wrong, corrected)
    }

    /// Content/sensitivity classification remains mandatory even with a boundary.
    /// A one-character diff may be ambiguous; the observed whole-term boundary
    /// resolves only that ambiguity, not unrelated factual or sentence rewrites.
    func suggestion(original: String, edited: String) -> (wrong: String, corrected: String)? {
        guard let pair = replacement(original: original, edited: edited),
              CorrectionSuggestionPhonetics.isPlausible(wrong: pair.wrong, corrected: pair.corrected)
        else { return nil }
        guard !UserEditClassifier.hasProtectedContentChange(original: original, edited: edited)
        else { return nil }
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: original,
            injectedRange: NSRange(original.startIndex..<original.endIndex, in: original),
            current: edited
        )
        switch result {
        case .candidate:
            guard UserEditClassifier.classify(original: original, edited: edited) == .lexicalCorrection
            else { return nil }
        case .rejected(.ambiguousCJKReplacement):
            break // Only the word extent was missing; the observed extent resolves it.
        default:
            return nil
        }
        return pair
    }
}

/// Keep only a bounded, verifiable edit extent. Missing AX selection support
/// falls back to observed contiguous deletion or the existing text diff.
struct CorrectionEditBoundaryTracker: Equatable, Sendable {
    private(set) var boundary: CorrectionEditBoundary?
    private var previousDeletion: NSRange?
    private(set) var hasProgressiveDeletion = false

    mutating func observeSelection(
        original: String, baselineFullValue: String,
        injectedRange: NSRange, selectedRange: NSRange?
    ) {
        // Called only while the field still equals the injection baseline.
        boundary = nil
        previousDeletion = nil
        hasProgressiveDeletion = false
        guard injectedRange.location >= 0, injectedRange.length >= 0,
              injectedRange.location <= baselineFullValue.utf16.count,
              injectedRange.length <= baselineFullValue.utf16.count - injectedRange.location,
              let selectedRange, selectedRange.length >= 0,
              selectedRange.location >= injectedRange.location,
              selectedRange.length <= injectedRange.length,
              selectedRange.location <= NSMaxRange(injectedRange) - selectedRange.length,
              Range(selectedRange, in: baselineFullValue) != nil
        else { return }
        let relative = NSRange(location: selectedRange.location - injectedRange.location,
                               length: selectedRange.length)
        guard let range = Range(relative, in: original),
              CorrectionSuggestionPhonetics.isCompactHanTerm(String(original[range])) else { return }
        boundary = CorrectionEditBoundary(range: relative, source: .selection)
    }

    mutating func observeValue(original: String, current: String) {
        if original == current {
            self = Self()
            return
        }
        guard let deleted = Self.contiguousDeletion(original: original, current: current) else { return }
        if let previousDeletion,
           deleted.location <= previousDeletion.location,
           NSMaxRange(deleted) >= NSMaxRange(previousDeletion),
           deleted.length > previousDeletion.length {
            hasProgressiveDeletion = true
        } else if previousDeletion != deleted {
            hasProgressiveDeletion = false
        }
        previousDeletion = deleted
        if let existing = boundary, existing.source == .selection,
           existing.range.location <= deleted.location,
           NSMaxRange(existing.range) >= NSMaxRange(deleted) { return }
        guard let range = Range(deleted, in: original),
              CorrectionSuggestionPhonetics.isCompactHanTerm(String(original[range])) else {
            boundary = nil
            return
        }
        boundary = CorrectionEditBoundary(range: deleted, source: .deletion)
    }

    /// Never extend an unqualified send/clear into the next message. Bridge a
    /// transient reset only with a prior selection or progressive deletion.
    func mayBridgeReset(original: String, current: String) -> Bool {
        guard let boundary,
              boundary.source == .selection || hasProgressiveDeletion,
              let deleted = Self.contiguousDeletion(original: original, current: current)
        else { return false }
        return deleted == boundary.range
    }

    private static func contiguousDeletion(original: String, current: String) -> NSRange? {
        let old = Array(original), new = Array(current)
        guard old.count > new.count else { return nil }
        var prefix = 0
        while prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        let removedCount = old.count - new.count
        guard Array(old[(prefix + removedCount)...]) == Array(new[prefix...]) else { return nil }
        let start = original.index(original.startIndex, offsetBy: prefix)
        let end = original.index(start, offsetBy: removedCount)
        return NSRange(start..<end, in: original)
    }
}

/// A rendezvous between analysis completion and the quiet-period deadline.
/// Either event may happen first. Revisions reject A→B→A stale completions.
struct CorrectionPresentationGate: Equatable, Sendable {
    private(set) var revision: UInt64 = 0
    private var analysisReady = false
    private var deadlineReached = false

    @discardableResult
    mutating func invalidate() -> UInt64 {
        revision &+= 1
        analysisReady = false
        deadlineReached = false
        return revision
    }

    mutating func analyzed(revision: UInt64) -> Bool {
        guard revision == self.revision else { return false }
        analysisReady = true
        return deadlineReached
    }

    mutating func reachedDeadline(revision: UInt64) -> Bool {
        guard revision == self.revision else { return false }
        deadlineReached = true
        return analysisReady
    }
}

/// An unresolved reset must not be sampled as a fresh edit by next-recording,
/// cancellation or timeout finalization. Preserve the last reliable old field.
struct CorrectionFinalizationDecision: Equatable, Sendable {
    let reason: UserEditObservationEndReason
    let shouldCaptureFinalSnapshot: Bool

    init(requested: UserEditObservationEndReason, pendingReset: UserEditObservationEndReason?) {
        reason = pendingReset ?? requested
        shouldCaptureFinalSnapshot = pendingReset == nil
            && requested != .valueCleared && requested != .structureChanged
    }
}
