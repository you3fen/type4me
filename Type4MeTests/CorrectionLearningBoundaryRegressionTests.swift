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
