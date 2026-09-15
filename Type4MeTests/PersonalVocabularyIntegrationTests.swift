import Foundation
import XCTest
import Type4MeIntelliSenseCore
@testable import Type4Me

final class PersonalVocabularyIntegrationTests: XCTestCase {
    func testExistingRequestCarriesVocabularyAndKeepsSingleCall() async {
        let client = VocabularyMockClient(output: "请打开 Type4Me。")
        let result = await run(text: "请打开太不封闭。", vocabulary: ["Type4Me"], client: client)
        let prompts = await client.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("<personal_vocabulary>"))
        XCTAssertTrue(prompts[0].contains("- Type4Me"))
        XCTAssertEqual(result?.text, "请打开 Type4Me。")
    }

    func testConfirmedReferenceUsesSameRequestAndAllowsBrandButNotNewVersion() async {
        let reference = VocabularyCorrectionReference(wrongText: "Tell me", correctedText: "Type4Me",
            bundleIdentifier: "com.example.editor", sourceRecordID: "synthetic-edit")
        let input = "把 Tell me 切换到 2.5 版本。"
        let good = "把 Type4Me 切换到 2.5 版本。"
        let client = VocabularyMockClient(output: good)
        let result = await run(text: input, vocabulary: ["Type4Me"], client: client, references: [reference])
        let prompts = await client.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("<confirmed_spelling_references>"))
        XCTAssertEqual(result?.text, good)
        let bad = await run(text: input, vocabulary: ["Type4Me"], client: VocabularyMockClient(output: "把 Type4Me 切换到 2.6 版本。"), references: [reference])
        XCTAssertEqual(bad?.text, input)
    }

    func testCancelledInputDoesNotAddPolishingRequest() async {
        let client = VocabularyMockClient(output: "不应使用")
        _ = await run(text: "请打开太不封闭。", vocabulary: ["Type4Me"], client: client, cancelled: true)
        let prompts = await client.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testShortTextExemptionStillSkipsRequest() async {
        let client = VocabularyMockClient(output: "不应使用")
        _ = await run(text: "打开它", vocabulary: ["Type4Me"], client: client, threshold: 100)
        let prompts = await client.prompts
        XCTAssertTrue(prompts.isEmpty)
    }

    func testSensitiveProcessingNeverSendsVocabulary() async {
        let client = VocabularyMockClient(output: "请保留这段话。")
        _ = await run(text: "请保留这段话。", vocabulary: ["PrivateTerm"], client: client, sensitive: true)
        let prompts = await client.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(prompts[0].contains("PrivateTerm"))
    }

    func testGuardStillRejectsInventedVersionInMockReply() async {
        let input = "把 Tell me 切换到 2.5 版本。"
        let client = VocabularyMockClient(output: "把 Type4Me 切换到 2.6 版本。")
        let result = await run(text: input, vocabulary: ["Type4Me", "2.6"], client: client)
        XCTAssertEqual(result?.text, input)
        XCTAssertTrue(result?.trace?.contains("protectedTokenChanged") == true)
    }

    func testNinePreservationControlsArePassedThroughByMockWithoutForcedRules() async {
        // Author-specified synthetic controls, not observed ASR accuracy evidence.
        let controls = [
            "这个视频使用 H.264 Codec。", "请用 Typeform 制作表单。",
            "这是 Tableau 的可视化教程。", "这里的 Cortex 指 CPU 内核，不是 Codex。",
            "Cloud Code 是原文的产品名，请保留。", "Tell me what happened.",
            "这套系统太不封闭，外部访问应该收紧。", "foo_Codec_bar",
            "AudioCodecFactory 的名称不要改。",
        ]
        for text in controls {
            let result = await run(text: text, vocabulary: ["Type4Me", "Codex", "Typeless", "Claude Code"], client: VocabularyMockClient(output: text))
            XCTAssertEqual(result?.text, text)
        }
    }

    func testLearningDescriptionChangesWithLanguageAndScope() {
        XCTAssertEqual(CorrectionLearningCardCopy.detail(scope: .hotwordOnly, language: "zh"), "记住正确词，保留现有替换规则")
        XCTAssertEqual(CorrectionLearningCardCopy.detail(scope: .hotwordOnly, language: "en"), "Remember the word; keep existing replacements")
        XCTAssertEqual(CorrectionLearningCardCopy.detail(scope: .hotwordAndMapping, language: "zh"), "添加到热词和片段替换")
        XCTAssertEqual(CorrectionLearningCardCopy.detail(scope: .hotwordAndMapping, language: "en"), "Add to hotwords and replacements")
    }

    private func run(text: String, vocabulary: [String], client: VocabularyMockClient,
                     cancelled: Bool = false, threshold: Int = 0, sensitive: Bool = false, references: [VocabularyCorrectionReference] = []) async -> (text: String, trace: String?)? {
        let target = TargetApplicationContext(processIdentifier: nil, bundleIdentifier: "com.example.editor", displayName: "Editor")
        let snapshot = IntelliSenseContextSnapshot(bundleIdentifier: target.bundleIdentifier, appName: "Editor", appCategory: .development, controlCategory: .multiLine, contextBeforeCursor: "", contextAfterCursor: "", availability: sensitive ? .sensitive : .appAndControl, wasTruncated: false)
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        return await session.processIntelliSenseForTesting(text: text, startingSnapshot: snapshot, settings: IntelliSenseSettings(), cancelled: cancelled, shortTextExemption: threshold, personalVocabulary: vocabulary, correctionReferences: references, currentTarget: { target }, capture: { _, _ in snapshot })
    }
}

private actor VocabularyMockClient: LLMClient {
    private let output: String
    private(set) var prompts: [String] = []
    init(output: String) { self.output = output }
    func process(text: String, prompt: String, config: LLMConfig, inputBoundary: LLMInputBoundary) async throws -> String {
        prompts.append(prompt)
        return output
    }
    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}
