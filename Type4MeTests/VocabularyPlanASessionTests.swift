import XCTest
import Type4MeIntelliSenseCore
@testable import Type4Me

final class VocabularyPlanASessionTests: XCTestCase {
    func testRelevantNewWordReachesActualSessionPromptWithoutExtraCall() async {
        let client = PlanAMock(output: "打开 FutureTool。")
        let result = await run(client, words: (0..<20).map { "Unrelated\($0)" } + ["FutureTool"])
        let prompts = await client.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("- FutureTool"))
        XCTAssertEqual(result?.text, "打开 FutureTool。")
    }

    func testExplicitSharedReferenceWorksInProcessingAppWithoutSecondRequest() async {
        let client = PlanAMock(output: "把 Type4Me 切换到 2.5 版本。")
        let reference = VocabularyCorrectionReference(wrongText: "Tell me", correctedText: "Type4Me",
            bundleIdentifier: "com.example.origin", sourceRecordID: "synthetic", sharedAcrossApps: true)
        let result = await run(client, text: "把 Tell me 切换到 2.5 版本。", references: [reference])
        let prompts = await client.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("Tell me → Type4Me"))
        XCTAssertEqual(result?.text, "把 Type4Me 切换到 2.5 版本。")
    }

    func testSharedReferenceDoesNotBypassSensitiveProcessingGate() async {
        let client = PlanAMock(output: "保留原文。")
        let reference = VocabularyCorrectionReference(wrongText: "Tell me", correctedText: "Type4Me",
            bundleIdentifier: "com.example.origin", sourceRecordID: "synthetic", sharedAcrossApps: true)
        _ = await run(client, text: "保留原文。", words: ["PrivateTerm"], references: [reference], sensitive: true)
        let prompts = await client.prompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertFalse(prompts[0].contains("<confirmed_spelling_references>"))
        XCTAssertFalse(prompts[0].contains("PrivateTerm"))
    }

    private func run(_ client: PlanAMock, text: String = "打开 Future Tool。", words: [String] = [],
                     references: [VocabularyCorrectionReference] = [], sensitive: Bool = false) async -> RecognitionSession.IntelliSenseOutputForTesting? {
        let target = TargetApplicationContext(processIdentifier: nil, bundleIdentifier: "com.example.destination", displayName: "Editor")
        let context = IntelliSenseContextSnapshot(bundleIdentifier: target.bundleIdentifier, appName: "Editor",
            appCategory: .document, controlCategory: .multiLine, contextBeforeCursor: "", contextAfterCursor: "",
            availability: sensitive ? .sensitive : .appAndControl, wasTruncated: false)
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        return await session.processIntelliSenseForTesting(text: text, startingSnapshot: context,
            settings: IntelliSenseSettings(), personalVocabulary: words, correctionReferences: references,
            currentTarget: { target }, capture: { _, _ in context })
    }
}

private actor PlanAMock: LLMClient {
    let output: String
    private(set) var prompts: [String] = []
    init(output: String) { self.output = output }
    func process(text: String, prompt: String, config: LLMConfig, inputBoundary: LLMInputBoundary) async throws -> String {
        prompts.append(prompt)
        return output
    }
    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}
