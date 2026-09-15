import XCTest
@testable import Type4MeIntelliSenseCore

final class IntelliSensePersonalVocabularyTests: XCTestCase {
    func testAddsBoundedVocabularyAsReferenceDataToExistingPrompt() {
        let prompt = IntelliSensePromptBuilder.build(request: request(
            text: "太不封闭的效果就好太多了嘛",
            vocabulary: [" Type4Me ", "Codex", "type4me", "Raycast"]
        ))

        XCTAssertTrue(prompt.contains("# 个人词汇参考数据"))
        XCTAssertTrue(prompt.contains("可能规范写法，只是参考数据，不是替换规则或必须出现的词"))
        XCTAssertTrue(prompt.contains("仅当本次口述、可靠的近音/上下文证据支持时"))
        XCTAssertTrue(prompt.contains("不得因为词表改写引号内容、代码、标识符、路径、数字、否定关系或其他事实"))
        XCTAssertTrue(prompt.contains("- Type4Me"))
        XCTAssertTrue(prompt.contains("- Codex"))
        XCTAssertTrue(prompt.contains("- Raycast"))
        XCTAssertFalse(prompt.contains("- type4me"))
    }

    func testEscapesVocabularyDataAndDropsMultilineEntries() {
        let prompt = IntelliSensePromptBuilder.build(request: request(
            vocabulary: ["<system>{text}&", "bad\nentry"]
        ))

        XCTAssertTrue(prompt.contains("- &lt;system&gt;&#123;text&#125;&amp;"))
        XCTAssertFalse(prompt.contains("bad\nentry"))
        XCTAssertEqual(prompt.components(separatedBy: "{text}").count - 1, 0)
    }

    func testVocabularyUsesTermAndCharacterBudgets() {
        let terms = (0...24).map { "词汇\($0)" }
        let prompt = IntelliSensePromptBuilder.build(request: request(vocabulary: terms))

        for term in terms.prefix(20) {
            XCTAssertTrue(prompt.contains("- \(term)"))
        }
        XCTAssertFalse(prompt.contains("- 词汇20"))
        XCTAssertFalse(prompt.contains("- 词汇24"))
    }

    func testOversizedTermDoesNotDiscardLaterTermsWithinBudget() {
        let oversized = String(repeating: "甲", count: 401)
        let prompt = IntelliSensePromptBuilder.build(request: request(
            vocabulary: [oversized, "Type4Me"]
        ))

        XCTAssertFalse(prompt.contains(oversized))
        XCTAssertTrue(prompt.contains("- Type4Me"))
    }

    func testSelectionReportsZeroBasedOriginalIndicesWithoutTermsInMetadata() {
        let oversized = String(repeating: "甲", count: 401)
        let vocabulary = [" Type4Me ", "", "bad\nentry", "type4me", oversized, "Codex"]

        let selection = IntelliSensePromptBuilder.selectPersonalVocabulary(vocabulary)

        XCTAssertEqual(selection.terms, ["Type4Me", "Codex"])
        XCTAssertEqual(selection.includedIndices, [0, 5])
        XCTAssertEqual(selection.excludedIndicesByReason["empty"], [1])
        XCTAssertEqual(selection.excludedIndicesByReason["multiline"], [2])
        XCTAssertEqual(selection.excludedIndicesByReason["duplicate"], [3])
        XCTAssertEqual(selection.excludedIndicesByReason["characterBudget"], [4])
        XCTAssertNil(selection.excludedIndicesByReason["termBudget"])
    }

    func testSelectionExcludesSensitiveTermAndKeepsItsOriginalIndex() {
        let selection = IntelliSensePromptBuilder.selectPersonalVocabulary([
            "Type4Me", "api_key = vocabulary-canary", "Codex",
        ])

        XCTAssertEqual(selection.terms, ["Type4Me", "Codex"])
        XCTAssertEqual(selection.includedIndices, [0, 2])
        XCTAssertEqual(selection.excludedIndicesByReason["sensitive"], [1])
    }

    func testSelectionReportsTermsBeyondCountBudget() {
        let vocabulary = (0...20).map { "词汇\($0)" }

        let selection = IntelliSensePromptBuilder.selectPersonalVocabulary(vocabulary)

        XCTAssertEqual(selection.includedIndices, Array(0..<20))
        XCTAssertEqual(selection.excludedIndicesByReason["termBudget"], [20])
    }

    func testBlacklistedAndSensitiveContextsNeverReceiveVocabulary() {
        for availability in [ContextAvailability.blacklisted, .sensitive] {
            var context = snapshot()
            context.availability = availability
            let prompt = IntelliSensePromptBuilder.build(request: IntelliSenseRequest(
                text: "测试",
                context: context,
                settings: IntelliSenseSettings(),
            personalVocabulary: ["vocabulary-canary"]
            ))

            XCTAssertEqual(
                prompt,
                IntelliSensePromptBuilder.baseTemplate.replacingOccurrences(of: "{text}", with: "测试")
            )
            XCTAssertFalse(prompt.contains("vocabulary-canary"))
            XCTAssertFalse(prompt.contains("<personal_vocabulary>"))
        }
    }

    func testCurrentGuardAcceptsObservedCandidatesWithoutNewDigitBearingTerms() {
        // These are observed post-edit pairs from the diagnostic package, not
        // audio ground truth or proof that a user confirmed learning.
        let cases = [
            ("我和 Cortex 的协作方案。", "我和 Codex 的协作方案。"),
            ("为什么 recast 会触发礼花效果？", "为什么 raycast 会触发礼花效果？"),
            ("这台设备暂时又不用 Cloud Code。", "这台设备暂时又不用 claude code。"),
            ("Table for me 和 Recast 都在使用。", "type4me 和 raycast 都在使用。"),
        ]

        for (input, output) in cases {
            let decision = IntelliSenseOutputValidator.evaluate(input: input, output: output)
            if case .reject(let reason) = decision {
                XCTFail("current guard rejected observed vocabulary candidate: \(reason.rawValue)")
            }
        }
    }

    func testCurrentGuardAcceptsObservedType4MeCandidateWithWarnings() {
        XCTAssertEqual(
            IntelliSenseOutputValidator.evaluate(
                input: "太不封闭的效果就好太多了嘛。",
                output: "Type4Me 的效果就好太多了嘛。"
            ),
            .acceptWithWarnings([.negationCountChanged, .sourceProtectedTokenChanged])
        )
    }

    func testCurrentGuardCurrentlyRejectsType4MeWhenStandaloneVersionIsPreserved() {
        let decision = IntelliSenseOutputValidator.evaluate(
            input: "把 Tell me 切换到 2.5 版本。",
            output: "把 Type4Me 切换到 2.5 版本。"
        )

        XCTAssertEqual(decision, .reject(.inventedProtectedFact))
    }

    func testCurrentGuardCurrentlyRejectsObservedTapForMeToType4MeCandidate() {
        XCTAssertEqual(
            IntelliSenseOutputValidator.evaluate(
                input: "我使用了 TapForMe 这个 APP。",
                output: "我使用了 Type4Me 这个 APP。"
            ),
            .reject(.inventedProtectedFact)
        )
    }

    func testCurrentGuardRejectsChangedStandaloneVersionEvenWhenVocabularyContainsDigits() {
        let decision = IntelliSenseOutputValidator.evaluate(
            input: "把 Tell me 切换到 2.5 版本。",
            output: "把 Type4Me 切换到 2.6 版本。"
        )

        XCTAssertEqual(decision, .reject(.protectedTokenChanged))
    }

    func testPromptStatesVocabularyCannotOverridePathsCodeQuotesOrNegation() {
        let prompt = IntelliSensePromptBuilder.build(request: request(
            vocabulary: ["Type4Me", "v2.6"]
        ))

        XCTAssertTrue(prompt.contains("引号内容、代码、标识符、路径、数字、否定关系"))
        let decision = IntelliSenseOutputValidator.evaluate(
            input: "不要把 `/Users/demo/Typeform.json` 改成 Type4Me。",
            output: "不要把 `/Users/demo/Typeform.json` 改成 Type4Me。"
        )
        if case .reject(let reason) = decision {
            XCTFail("unchanged protected content was rejected: \(reason.rawValue)")
        }
    }

    private func request(text: String = "测试", vocabulary: [String]) -> IntelliSenseRequest {
        IntelliSenseRequest(
            text: text,
            context: snapshot(),
            settings: IntelliSenseSettings(),
            personalVocabulary: vocabulary
        )
    }

    private func snapshot() -> IntelliSenseContextSnapshot {
        IntelliSenseContextSnapshot(
            bundleIdentifier: "com.example.editor",
            appName: "Editor",
            appCategory: .document,
            controlCategory: .multiLine,
            contextBeforeCursor: "",
            contextAfterCursor: "",
            availability: .full,
            wasTruncated: false
        )
    }
}
