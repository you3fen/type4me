import Foundation
import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

/// Text/AX-evidence replay, not audio recognition or real editor UI acceptance.
final class CorrectionDiscoveryRegressionTests: XCTestCase {
    private let segmenter = DiscoveryEmptySegmenter()
    private func whole(_ text: String, source: CorrectionEditBoundary.Source = .selection) -> CorrectionEditBoundary {
        .init(range: NSRange(text.startIndex..<text.endIndex, in: text), source: source)
    }
    private func result(_ original: String, _ edited: String,
                        boundary: CorrectionEditBoundary? = nil) async -> ImmediateCorrectionCandidateResult {
        await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: original, edited: edited, chineseSegmenter: segmenter,
            confirmedMappings: [], editBoundary: boundary
        )
    }

    func testReportedNasalConfusionRemainsStrictlyRejectedButOffersSoftConfirmation() async {
        let original = "请查询身材有数。", edited = "请查询生财有术。"
        let strict = await ImmediateCorrectionAnalyzer.analyze(
            original: original, edited: edited, chineseSegmenter: segmenter, confirmedMappings: []
        )
        XCTAssertEqual(strict, .rejected(.lowAffinity))
        XCTAssertFalse(CorrectionAffinityAnalyzer.evaluate(wrong: "身材有数", corrected: "生财有术").isHighConfidence)
        let immediate = await result(original, edited)
        XCTAssertEqual(immediate, .candidate(wrongText: "身材有数", correctedText: "生财有术", learningScope: .softReference))
    }

    func testBoundedPronunciationFamiliesWithoutWeakeningBatchAffinity() async {
        for (wrong, correct) in [("陈晨", "程陈"), ("金林", "经琳"), ("山兰", "商蓝"), ("牛林", "刘琳")] {
            XCTAssertTrue(CorrectionSuggestionPhonetics.isPlausible(wrong: wrong, corrected: correct), wrong)
            XCTAssertFalse(CorrectionAffinityAnalyzer.evaluate(wrong: wrong, corrected: correct).isHighConfidence, wrong)
            let actual = await result("请联系\(wrong)。", "请联系\(correct)。")
            XCTAssertEqual(actual, .candidate(wrongText: wrong, correctedText: correct, learningScope: .softReference), wrong)
        }
    }

    func testPhoneticsDoesNotBecomeGeneralSimilarityOrUnlimitedVariantGeneration() {
        for (wrong, correct) in [
            ("苹果", "香蕉"), ("中国", "美国"), ("身材有数", "生财有道"),
            ("陈林", "陈琳子"), ("陈", "程"), ("甲乙丙丁戊己庚辛壬", "甲乙丙丁戊己庚辛仁"),
            ("牛林", "刘玲"), // two confused syllables in a two-character term
            ("南京", "良经"), // n/l AND an/ang in the same syllable
            ("CodeX", "Codex"), ("陈 晨", "程 陈"), ("123", "124")
        ] {
            XCTAssertFalse(CorrectionSuggestionPhonetics.isPlausible(wrong: wrong, corrected: correct), wrong)
        }
    }

    func testSingleCharacterStillAbstainsWithoutObservedWordBoundary() async {
        let actual = await result("请查询生财有数。", "请查询生财有术。")
        XCTAssertEqual(actual, .rejected(.ambiguousCJKReplacement))
    }

    func testSelectedWholeFourCharacterTermSurvivesOneCharacterMinimalDiff() async {
        let original = "请查询生财有数。", edited = "请查询生财有术。"
        let range = NSRange(original.range(of: "生财有数")!, in: original)
        let actual = await result(original, edited, boundary: .init(range: range, source: .selection))
        XCTAssertEqual(actual, .candidate(wrongText: "生财有数", correctedText: "生财有术", learningScope: .softReference))
    }

    func testSelectedTwoCharacterTermInOtherwiseEmptyEditorIsNotAnEditSizeHeuristicRejection() async {
        let actual = await result("南林", "蓝林", boundary: whole("南林"))
        XCTAssertEqual(actual, .candidate(wrongText: "南林", correctedText: "蓝林", learningScope: .softReference))
    }

    func testOnlyEditedSuffixDoesNotInventUnobservedWholeWordExtent() async {
        let original = "请查询生财有数。", edited = "请查询生财有术。"
        let range = NSRange(original.range(of: "有数")!, in: original)
        let actual = await result(original, edited, boundary: .init(range: range, source: .selection))
        XCTAssertEqual(actual, .candidate(wrongText: "有数", correctedText: "有术", learningScope: .softReference))
    }

    func testSelectedBoundaryCannotLearnDifferentOccurrenceOrUnrelatedSurroundingEdit() {
        let original = "生财有数，生财有数。"
        let boundary = CorrectionEditBoundary(range: NSRange(location: 0, length: 4), source: .selection)
        XCTAssertNil(boundary.suggestion(original: original, edited: "生财有数，生财有术。"))
        XCTAssertNil(boundary.suggestion(original: "请查询生财有数。", edited: "不要查询生财有术。"))
    }

    func testBoundaryStillRejectsSensitiveNumericNegationAndOrdinaryRewrites() async {
        for (original, edited) in [
            ("不用", "布用"), ("费用3.9元，身材有数。", "费用309元，生财有术。"),
            ("联系 a@example.invalid 身材有数。", "联系 a@example.invalid 生财有术。"),
            ("打开 https://example.invalid/身材有数", "打开 https://example.invalid/生财有术"),
            ("我觉得今天方案需要改变。", "下周再讨论访问策略。"),
            ("这个东西不太需要。", "这个东西不在需要。")
        ] {
            let actual = await result(original, edited, boundary: whole(original))
            if case .candidate = actual { XCTFail("must abstain: \(original)") }
        }
    }

    func testSelectionUsesProjectedUTF16RatherThanCharacterCount() {
        let raw = "\u{200B}😀：生财有数。", original = "生财有数"
        let projection = VisibleTextProjection.project(raw)
        let rawRange = NSRange(raw.range(of: original)!, in: raw)
        let visibleRange = projection.projectedRange(from: rawRange)!
        XCTAssertEqual(visibleRange.location, 3) // emoji is two UTF-16 code units
        var tracker = CorrectionEditBoundaryTracker()
        tracker.observeSelection(original: original, baselineFullValue: projection.text,
                                 injectedRange: visibleRange, selectedRange: visibleRange)
        XCTAssertEqual(tracker.boundary?.range, NSRange(location: 0, length: 4))
        XCTAssertNotNil(tracker.boundary?.suggestion(original: original, edited: "生财有术"))
    }

    func testOutOfInjectionSingleCharacterAndOverflowSelectionsDoNotProvideBoundary() {
        var tracker = CorrectionEditBoundaryTracker()
        for range in [NSRange(location: 0, length: 2), NSRange(location: 4, length: 1),
                      NSRange(location: NSNotFound, length: 5), NSRange(location: 3, length: Int.max)] {
            tracker.observeSelection(original: "生财有数", baselineFullValue: "前缀：生财有数。",
                                     injectedRange: NSRange(location: 3, length: 4), selectedRange: range)
            XCTAssertNil(tracker.boundary)
        }
        XCTAssertNil(CorrectionEditBoundary(range: NSRange(location: Int.max, length: Int.max), source: .selection)
            .suggestion(original: "生财有数", edited: "生财有术"))
    }

    func testCollapsedSelectionClearsStalePreEditExtent() {
        var tracker = CorrectionEditBoundaryTracker()
        tracker.observeSelection(original: "生财有数", baselineFullValue: "生财有数",
                                 injectedRange: NSRange(location: 0, length: 4), selectedRange: NSRange(location: 0, length: 4))
        XCTAssertNotNil(tracker.boundary)
        tracker.observeSelection(original: "生财有数", baselineFullValue: "生财有数",
                                 injectedRange: NSRange(location: 0, length: 4), selectedRange: NSRange(location: 4, length: 0))
        XCTAssertNil(tracker.boundary)
    }

    func testProgressiveBackspaceRetainsWholeTermExtentThroughRetyping() async {
        let original = "请查询生财有数。"
        var tracker = CorrectionEditBoundaryTracker()
        for value in ["请查询生财有。", "请查询生财。", "请查询生。", "请查询。", "请查询生财有术。"] {
            tracker.observeValue(original: original, current: value)
        }
        XCTAssertEqual(tracker.boundary?.range, NSRange(location: 3, length: 4))
        XCTAssertTrue(tracker.hasProgressiveDeletion)
        let actual = await result(original, "请查询生财有术。", boundary: tracker.boundary)
        XCTAssertEqual(actual, .candidate(wrongText: "生财有数", correctedText: "生财有术", learningScope: .softReference))
    }

    func testForwardDeleteAlsoRetainsObservedTermExtent() {
        var tracker = CorrectionEditBoundaryTracker()
        for value in ["财有数", "有数", "数", ""] { tracker.observeValue(original: "生财有数", current: value) }
        XCTAssertTrue(tracker.mayBridgeReset(original: "生财有数", current: ""))
        XCTAssertNotNil(tracker.boundary?.suggestion(original: "生财有数", edited: "生财有术"))
    }

    func testWholeFieldSendOrClearWithoutPriorEvidenceNeverStartsGrace() {
        var tracker = CorrectionEditBoundaryTracker()
        tracker.observeValue(original: "生财有数", current: "")
        XCTAssertFalse(tracker.mayBridgeReset(original: "生财有数", current: ""))
        XCTAssertFalse(tracker.hasProgressiveDeletion)
    }

    func testSelectedWholeTermAllowsTransientEmptyButCannotLearnUnrelatedNextMessage() {
        var tracker = CorrectionEditBoundaryTracker()
        tracker.observeSelection(original: "生财有数", baselineFullValue: "生财有数",
                                 injectedRange: NSRange(location: 0, length: 4), selectedRange: NSRange(location: 0, length: 4))
        tracker.observeValue(original: "生财有数", current: "")
        XCTAssertTrue(tracker.mayBridgeReset(original: "生财有数", current: ""))
        XCTAssertNil(tracker.boundary?.suggestion(original: "生财有数", edited: "现在出发"))
        XCTAssertNil(tracker.boundary?.suggestion(original: "生财有数", edited: "shengcaiyoushu"))
        XCTAssertNil(tracker.boundary?.suggestion(original: "生财有数", edited: ""))
    }

    func testUndoToOriginalClearsBothDeletionAndSelectionEvidence() {
        var tracker = CorrectionEditBoundaryTracker()
        for value in ["生财有", "生财", "生财有数"] { tracker.observeValue(original: "生财有数", current: value) }
        XCTAssertNil(tracker.boundary)
        XCTAssertFalse(tracker.hasProgressiveDeletion)
    }

    func testPureDeletionAndPureInsertionAreNotCorrectionCandidates() async {
        for edited in ["", "请查询。", "请查询生财有数及其他内容。"] {
            let actual = await result("请查询生财有数。", edited, boundary: whole("请查询生财有数。"))
            if case .candidate = actual { XCTFail("insertion/deletion must not be learned") }
        }
    }

    func testPresentationRendezvousSupportsAnalysisBeforeDeadline() {
        var gate = CorrectionPresentationGate()
        let revision = gate.invalidate()
        XCTAssertFalse(gate.analyzed(revision: revision))
        XCTAssertTrue(gate.reachedDeadline(revision: revision))
    }

    func testPresentationRendezvousSupportsSlowAnalysisAfterDeadline() {
        var gate = CorrectionPresentationGate()
        let revision = gate.invalidate()
        XCTAssertFalse(gate.reachedDeadline(revision: revision))
        XCTAssertTrue(gate.analyzed(revision: revision))
    }

    func testStaleABAAnalysisAndDeadlineCannotUnlockNewRevision() {
        var gate = CorrectionPresentationGate()
        let firstA = gate.invalidate()
        _ = gate.invalidate() // B
        let secondA = gate.invalidate()
        XCTAssertFalse(gate.analyzed(revision: firstA))
        XCTAssertFalse(gate.reachedDeadline(revision: firstA))
        XCTAssertFalse(gate.reachedDeadline(revision: secondA))
        XCTAssertTrue(gate.analyzed(revision: secondA))
    }

    func testFinalizeDisableAndAmbiguityInvalidateReadiness() {
        var gate = CorrectionPresentationGate()
        for _ in 0..<3 {
            let old = gate.invalidate()
            XCTAssertFalse(gate.analyzed(revision: old))
            let current = gate.invalidate()
            XCTAssertFalse(gate.reachedDeadline(revision: old))
            XCTAssertFalse(gate.reachedDeadline(revision: current))
        }
    }

    func testUnresolvedResetNeverSamplesNextMessageDuringOtherFinalizationPaths() {
        for requested: UserEditObservationEndReason in [
            .nextRecording, .cancelled, .timeout, .reviseStarted,
            .settingsDisabled, .appTerminated, .readFailure
        ] {
            for pending: UserEditObservationEndReason in [.valueCleared, .structureChanged] {
                let decision = CorrectionFinalizationDecision(requested: requested, pendingReset: pending)
                XCTAssertEqual(decision.reason, pending)
                XCTAssertFalse(decision.shouldCaptureFinalSnapshot)
            }
        }
    }

    func testNormalFinalizationKeepsExistingLastSnapshotBehavior() {
        XCTAssertTrue(CorrectionFinalizationDecision(requested: .nextRecording, pendingReset: nil).shouldCaptureFinalSnapshot)
        XCTAssertFalse(CorrectionFinalizationDecision(requested: .valueCleared, pendingReset: nil).shouldCaptureFinalSnapshot)
        XCTAssertFalse(CorrectionFinalizationDecision(requested: .structureChanged, pendingReset: nil).shouldCaptureFinalSnapshot)
    }

    func testDiscoveryDoesNotWriteAndSoftConfirmationDoesNotModifyMappings() async throws {
        let persistence = DiscoveryMemory()
        let previous = persistence.mappings
        let discovered = await result("请查询身材有数。", "请查询生财有术。")
        XCTAssertTrue(persistence.words.isEmpty)
        XCTAssertTrue(persistence.references.isEmpty)
        guard case .candidate(let wrong, let corrected, let scope) = discovered else { return XCTFail("no candidate") }
        try CorrectionLearningStore(persistence: persistence).learn(.init(
            wrongText: wrong, correctedText: corrected, sourceRecordID: "synthetic",
            bundleIdentifier: "com.example.editor", learningScope: scope))
        XCTAssertEqual(persistence.words, ["生财有术"])
        XCTAssertEqual(persistence.references.count, 1)
        XCTAssertEqual(persistence.references.first?.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(persistence.mappings, previous)
        XCTAssertEqual(persistence.mappingWrites, 0)
    }
}

private struct DiscoveryEmptySegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] { [] }
}

private final class DiscoveryMemory: CorrectionVocabularyPersisting {
    var words: [String] = []
    var mappings = [CorrectionMapping(trigger: "hello", replacement: "old shortcut")]
    var references: [VocabularyCorrectionReference] = []
    var mappingWrites = 0
    func loadHotwords() -> [String] { words }
    func loadMappings() -> [CorrectionMapping] { mappings }
    func saveHotwords(_ value: [String]) throws { words = value }
    func saveMappings(_ value: [CorrectionMapping]) throws { mappings = value; mappingWrites += 1 }
    func loadReferences() throws -> [VocabularyCorrectionReference] { references }
    func saveReferences(_ value: [VocabularyCorrectionReference]) throws { references = value }
}
