import Foundation
import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

/// Pairs are shaped after real edits in local history; this checks the learning
/// rules, not ASR accuracy.
final class VocabularyEditLearnerTests: XCTestCase {
    private func correction(_ original: String, _ edited: String) -> VocabularyEditLearner.Correction? {
        VocabularyEditLearner.correction(original: original, edited: edited)
    }

    func testExtractsSingleTermReplacements() {
        XCTAssertEqual(correction("用 Recast 打开这个。", "用 Raycast 打开这个。"),
                       .init(wrong: "Recast", term: "Raycast"))
        XCTAssertEqual(correction("我用 Cloud Code 改代码", "我用 Claude code 改代码"),
                       .init(wrong: "Cloud Code", term: "Claude code"))
        XCTAssertEqual(correction("那个七瓷的项目", "那个栖迟的项目"),
                       .init(wrong: "七瓷", term: "栖迟"))
        XCTAssertEqual(correction("打开 TableForm 设置", "打开 Type4Me 设置"),
                       .init(wrong: "TableForm", term: "Type4Me"))
        XCTAssertEqual(correction("cloud 很好用", "Claude 很好用"),
                       .init(wrong: "cloud", term: "Claude"))
    }

    func testIgnoresEditsThatAreNotTermCorrections() {
        XCTAssertNil(correction("他说得对", "她说得对"), "single character")
        XCTAssertNil(correction("版本 3.9 发布", "版本 309 发布"), "number")
        XCTAssertNil(correction("我今天去公司", "我明天不去公司了"), "rewrite spans more than one term")
        XCTAssertNil(correction("先打开 A，再关闭 B", "先打开 C，再关闭 D"), "two separate edits")
        XCTAssertNil(correction("一样的文字", "一样的文字"))
        XCTAssertNil(correction("这是一段很长的原始口述内容需要改写", "完全不同的一句话"), "wrong side too long")
        XCTAssertNil(correction("用子 agent 处理", "用子 Agent处理"), "case-only change")
        XCTAssertNil(correction("那个西瓜", "那个子 Agent"), "mixed Chinese/Latin term")
    }

    func testPromotesOnlyAfterTheSecondCorrection() {
        var state = VocabularyEditLearner.State()
        let first = VocabularyEditLearner.record(.init(wrong: "Recast", term: "Raycast"), in: &state, knownVocabulary: [])
        XCTAssertNil(first)
        XCTAssertEqual(state.terms["raycast"]?.count, 1)
        let second = VocabularyEditLearner.record(.init(wrong: "Redis", term: "Raycast"), in: &state, knownVocabulary: [])
        XCTAssertEqual(second, "Raycast")
        XCTAssertNil(state.terms["raycast"], "promoted terms leave the tracked state")
    }

    func testOneOffTyposAndKnownTermsAreNeverPromoted() {
        var state = VocabularyEditLearner.State()
        XCTAssertNil(VocabularyEditLearner.record(.init(wrong: "异议", term: "isssue"), in: &state, knownVocabulary: []))
        XCTAssertNil(VocabularyEditLearner.record(.init(wrong: "Qdex", term: "codex"), in: &state, knownVocabulary: ["Codex"]))
        XCTAssertNil(VocabularyEditLearner.record(.init(wrong: "Cortex", term: "Codex"), in: &state, knownVocabulary: ["Codex"]))
        XCTAssertEqual(state.terms.count, 1)
        XCTAssertEqual(state.terms.values.first?.term, "isssue")
    }

    func testStoreAddsHotwordOnSecondEditAndPersistsCounts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocabulary-learning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = AddedTerms()
        let store = VocabularyLearningStore(
            fileURL: directory.appendingPathComponent("vocabulary-learning.json"),
            loadVocabulary: { ["Codex"] },
            addHotword: { await added.append($0) }
        )
        let none = await store.record(original: "用 Recast 打开", edited: "用 Raycast 打开")
        XCTAssertNil(none)
        let tracked = await store.trackedState()
        XCTAssertEqual(tracked.terms["raycast"]?.wrongForms, ["Recast"])
        let promoted = await store.record(original: "Recast 很好用", edited: "Raycast 很好用")
        XCTAssertEqual(promoted, "Raycast")
        let terms = await added.terms
        XCTAssertEqual(terms, ["Raycast"])
        let after = await store.trackedState()
        XCTAssertTrue(after.terms.isEmpty)
    }
}

private actor AddedTerms {
    private(set) var terms: [String] = []
    func append(_ term: String) { terms.append(term) }
}
