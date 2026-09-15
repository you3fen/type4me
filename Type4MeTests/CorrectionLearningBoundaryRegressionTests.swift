import Foundation
import XCTest
@testable import Type4Me

final class CorrectionLearningBoundaryRegressionTests: XCTestCase {
    func testLatinCorrectionDoesNotExpandAcrossAdjacentChinese() {
        for separator in ["", " ", "\u{00A0}", "\u{3000}"] {
            let original = "这是recast\(separator)的功能。"
            let edited = "这是raycast的功能。"
            XCTAssertEqual(
                CorrectionDiffAnalyzer.analyze(baseline: original, injectedRange: NSRange(original.startIndex..<original.endIndex, in: original), current: edited),
                .candidate(wrongText: "recast", correctedText: "raycast")
            )
        }
    }

    func testMixedScriptReplacementWithTrailingBoundaryWhitespaceKeepsExactTokens() {
        for boundaryWhitespace in [" ", "\u{00A0}", "\u{3000}"] {
            let original = "你不觉得吗？太不封闭的识别效果很好。"
            let edited = "你不觉得吗？type4me\(boundaryWhitespace)的识别效果很好。"
            let result = CorrectionDiffAnalyzer.analyze(
                baseline: original,
                injectedRange: NSRange(original.startIndex..<original.endIndex, in: original),
                current: edited
            )
            XCTAssertEqual(
                result,
                .candidate(wrongText: "太不封闭", correctedText: "type4me"),
                "failed boundary whitespace U+\(boundaryWhitespace.unicodeScalars.map { String(format: "%04X", $0.value) }.joined())"
            )
        }
    }

    func testMixedScriptReplacementKeepsCompoundTechnicalNameBesideChinese() {
        let original = "你不觉得吗？太不封闭的识别效果很好。"
        let edited = "你不觉得吗？Type4Me Pro 的识别效果很好。"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: original,
            injectedRange: NSRange(original.startIndex..<original.endIndex, in: original),
            current: edited
        )
        XCTAssertEqual(result, .candidate(wrongText: "太不封闭", correctedText: "Type4Me Pro"))
    }

    func testTrailingWhitespaceStillValidatesMixedScriptHanBoundary() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "明天早上还要跟杰瑞开会",
            edited: "明天早上还要跟Jerry 开会",
            chineseSegmenter: BoundaryDisagreeingSegmenter()
        )
        XCTAssertEqual(result, .rejected(.invalidCandidate))
    }

    func testLowAffinityMixedScriptCandidateCreatesSoftReferenceWithOrWithoutBoundaryWhitespace() async {
        for boundaryWhitespace in ["", " ", "\u{00A0}", "\u{3000}"] {
            let result = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
                original: "你不觉得吗？太不封闭的识别效果很好。",
                edited: "你不觉得吗？type4me\(boundaryWhitespace)的识别效果很好。",
                chineseSegmenter: BoundaryNoMatchSegmenter(),
                confirmedMappings: []
            )
            XCTAssertEqual(
                result,
                .candidate(wrongText: "太不封闭", correctedText: "type4me", learningScope: .softReference),
                "failed boundary whitespace U+\(boundaryWhitespace.unicodeScalars.map { String(format: "%04X", $0.value) }.joined())"
            )
        }
    }

    func testSoftReferenceSuggestionSurvivesMissingOrDisputedHanTokenBoundaries() async {
        let original = "你不觉得吗？太不封闭的识别效果很好。"
        let edited = "你不觉得吗？type4me 的识别效果很好。"
        let noTokenResult = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: original, edited: edited,
            chineseSegmenter: BoundaryNoMatchSegmenter(), confirmedMappings: []
        )
        let disputedBoundaryResult = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: original, edited: edited,
            chineseSegmenter: MixedScriptBoundaryDisagreeingSegmenter(), confirmedMappings: []
        )
        let expected: ImmediateCorrectionCandidateResult = .candidate(
            wrongText: "太不封闭", correctedText: "type4me", learningScope: .softReference
        )
        XCTAssertEqual(noTokenResult, expected)
        XCTAssertEqual(disputedBoundaryResult, expected)
    }

    func testHighAffinityCandidateDefaultsToReferenceScope() async {
        let result = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: "请打开 Ghotty", edited: "请打开 Ghostty", confirmedMappings: []
        )
        XCTAssertEqual(result, .candidate(wrongText: "Ghotty", correctedText: "Ghostty", learningScope: .softReference))
    }

    func testHotwordOnlyConfirmationDoesNotCreateReplacementRule() throws {
        let persistence = BoundaryLearningPersistence()
        let candidate = CorrectionCandidate(
            wrongText: "太不封闭", correctedText: "type4me", sourceRecordID: "synthetic-edit",
            bundleIdentifier: "com.example.editor", learningScope: .hotwordOnly
        )
        try CorrectionLearningStore(persistence: persistence).learn(candidate)
        XCTAssertEqual(persistence.hotwords, ["type4me"])
        XCTAssertTrue(persistence.mappings.isEmpty)
        XCTAssertEqual(persistence.mappingSaveCount, 0)
    }

    func testHotwordOnlyConfirmationKeepsExistingMappingsInOrder() throws {
        let existingMappings = [
            CorrectionMapping(trigger: "Codec", replacement: "codex"),
            CorrectionMapping(trigger: "Typeform", replacement: "Type4Me"),
            CorrectionMapping(trigger: "Tableau", replacement: "Typeless"),
            CorrectionMapping(trigger: "recast", replacement: "raycast"),
        ]
        let persistence = BoundaryLearningPersistence(hotwords: ["Codex"], mappings: existingMappings)
        let candidate = CorrectionCandidate(
            wrongText: "太不封闭", correctedText: "type4me", sourceRecordID: "synthetic-edit",
            bundleIdentifier: "com.example.editor", learningScope: .hotwordOnly
        )
        try CorrectionLearningStore(persistence: persistence).learn(candidate)
        XCTAssertEqual(persistence.hotwords, ["Codex", "type4me"])
        XCTAssertEqual(persistence.mappings, existingMappings)
        XCTAssertEqual(persistence.mappingSaveCount, 0)
    }

    func testMultipleEditsAndOrdinaryRewriteDoNotOfferCandidates() async {
        let multipleEdits = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: "请打开 Ghotty，然后关闭 Nextjs",
            edited: "请打开 Ghostty，然后关闭 Next.js", confirmedMappings: []
        )
        let ordinaryRewrite = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: "这个方案太不封闭，需要收紧访问。",
            edited: "下周再讨论访问策略。", confirmedMappings: []
        )
        XCTAssertEqual(multipleEdits, .rejected(.multipleChanges))
        if case .candidate = ordinaryRewrite { XCTFail("ordinary rewrite must not offer a correction candidate") }
    }

    func testSensitiveEditDoesNotOfferCandidate() async {
        let result = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: "请联系 wrong@example.com",
            edited: "请联系 type4me@example.com ", confirmedMappings: []
        )
        XCTAssertEqual(result, .rejected(.sensitiveContent))
    }

    func testMixedScriptShapeWithoutUnchangedNegationContextRemainsRejected() async {
        // Do not put “识别” in this fixture: the inherited classifier treats
        // its “别” as a negation marker, invalidating this test's precondition.
        // We are testing the existing content-edit gate, not weakening it.
        let original = "这个太不封闭的效果很好。"
        let edited = "这个Type4Me 的效果很好。"
        XCTAssertEqual(UserEditClassifier.classify(original: original, edited: edited), .contentEdit)
        let result = await ImmediateCorrectionAnalyzer.analyzeForImmediateCandidate(
            original: original, edited: edited,
            chineseSegmenter: BoundaryNoMatchSegmenter(), confirmedMappings: []
        )
        XCTAssertEqual(result, .rejected(.invalidCandidate))
    }
}

private struct BoundaryDisagreeingSegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] {
        guard let nameRange = text.range(of: "杰瑞"), let otherRange = text.range(of: "明天") else { return [] }
        return [ChineseTokenSpan(range: nameRange, source: .naturalLanguage), ChineseTokenSpan(range: otherRange, source: .jiebaAccurate)]
    }
}

private struct BoundaryNoMatchSegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] { [] }
}

private struct MixedScriptBoundaryDisagreeingSegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] {
        guard let candidateRange = text.range(of: "太不封闭"), let otherRange = text.range(of: "像这样看") else { return [] }
        return [ChineseTokenSpan(range: candidateRange, source: .naturalLanguage), ChineseTokenSpan(range: otherRange, source: .jiebaAccurate)]
    }
}

private final class BoundaryLearningPersistence: CorrectionVocabularyPersisting {
    var hotwords: [String]
    var mappings: [CorrectionMapping]
    var mappingSaveCount = 0
    init(hotwords: [String] = [], mappings: [CorrectionMapping] = []) {
        self.hotwords = hotwords
        self.mappings = mappings
    }
    func loadHotwords() -> [String] { hotwords }
    func loadMappings() -> [CorrectionMapping] { mappings }
    func saveHotwords(_ words: [String]) throws { hotwords = words }
    func saveMappings(_ mappings: [CorrectionMapping]) throws {
        self.mappings = mappings
        mappingSaveCount += 1
    }
}
