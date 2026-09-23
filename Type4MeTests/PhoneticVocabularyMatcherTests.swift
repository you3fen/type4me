import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

/// Sentences are shaped after real misrecognitions; this checks matching rules,
/// not ASR or model accuracy.
final class PhoneticVocabularyMatcherTests: XCTestCase {
    private let vocabulary = ["生财有术", "阶跃星辰", "菜獾", "虎码", "形码", "会话"]

    func testFoldsNasalRetroflexAndNLConfusions() {
        XCTAssertEqual(PhoneticVocabularyMatcher.fold("sheng"), "sen")
        XCTAssertEqual(PhoneticVocabularyMatcher.fold("xing"), "xin")
        XCTAssertEqual(PhoneticVocabularyMatcher.fold("chang"), "can")
        XCTAssertEqual(PhoneticVocabularyMatcher.fold("zhi"), "zi")
        XCTAssertEqual(PhoneticVocabularyMatcher.fold("lan"), "nan")
        XCTAssertEqual(PhoneticVocabularyMatcher.fold("hua"), "hua")
    }

    func testReplacesLongTermsHeardWithAccent() {
        let result = PhoneticVocabularyMatcher.applyReplacements(
            to: "你不知道身材有数吗？不过，街月星辰的这个也可以。", vocabulary: vocabulary
        )
        XCTAssertEqual(result.text, "你不知道生财有术吗？不过，阶跃星辰的这个也可以。")
        XCTAssertEqual(result.applied.map(\.term), ["生财有术", "阶跃星辰"])
        XCTAssertEqual(result.applied.map(\.window), ["身材有数", "街月星辰"])
    }

    func testTwoCharacterTermsAreNeverMatched() {
        for text in ["它可以正确识别蔡欢老师，胡码也行。", "一个月大概会花多少钱？"] {
            XCTAssertTrue(PhoneticVocabularyMatcher.matches(in: text, vocabulary: vocabulary).isEmpty, text)
        }
    }

    func testDoesNotRewriteOrdinaryWords() {
        for text in ["一个月大概会花多少钱？", "这是其他的模型吗？", "就必须要手动才行吗？", "她身材很好。"] {
            XCTAssertEqual(
                PhoneticVocabularyMatcher.applyReplacements(to: text, vocabulary: vocabulary).text, text, text
            )
        }
        XCTAssertTrue(PhoneticVocabularyMatcher.matches(in: "这是其他的模型吗？", vocabulary: vocabulary).isEmpty)
    }

    func testIgnoresExactTermsAndNonHanVocabulary() {
        let text = "生财有术和 Claude code"
        XCTAssertTrue(PhoneticVocabularyMatcher.matches(in: text, vocabulary: ["生财有术", "Claude code"]).isEmpty)
    }

    func testPhoneticProvenanceRoundTripsAndOldPayloadsStillDecode() {
        let rule = AppliedSnippetRule(trigger: "身材有数", value: "生财有术", bundleId: nil, origin: .phoneticVocabulary)
        let encoded = HistoryStore.encodeAppliedSnippets([rule])
        XCTAssertEqual(HistoryStore.decodeAppliedSnippets(encoded), [rule])
        let legacy = #"{"version":1,"rules":[{"trigger":"胡麻","value":"虎码"}]}"#
        XCTAssertEqual(HistoryStore.decodeAppliedSnippets(legacy)?.first?.origin, nil)
    }
}
