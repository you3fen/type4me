import Foundation
import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

/// Constructed text controls, not audio/ASR or real-model accuracy measurements.
final class VocabularyPlanATests: XCTestCase {
    private func context(_ bundle: String = "com.example.editor", _ availability: ContextAvailability = .appAndControl) -> IntelliSenseContextSnapshot {
        IntelliSenseContextSnapshot(bundleIdentifier: bundle, appName: "Editor", appCategory: .document,
            controlCategory: .multiLine, contextBeforeCursor: "", contextAfterCursor: "",
            availability: availability, wasTruncated: false)
    }
    private func candidate(_ wrong: String = "Tell me", _ correct: String = "Type4Me",
                           scope: CorrectionLearningScope = .softReference) -> CorrectionCandidate {
        CorrectionCandidate(wrongText: wrong, correctedText: correct, sourceRecordID: "synthetic-confirmation",
            bundleIdentifier: "com.example.editor", learningScope: scope)
    }
    private func reference(_ wrong: String, _ correct: String, shared: Bool? = nil) -> VocabularyCorrectionReference {
        VocabularyCorrectionReference(wrongText: wrong, correctedText: correct,
            bundleIdentifier: "com.example.editor", sourceRecordID: "synthetic", sharedAcrossApps: shared)
    }

    func testCaseAndSpaceEquivalentAppRuleOverridesGlobalWithCorrectProvenance() {
        let result = SnippetStorage.apply(to: "打开 Cloud Code。",
            globalRules: [("Cloud Code", "Claude Code")], appRules: [("cloudcode", "Cloud Code")],
            bundleId: "com.example.editor")
        XCTAssertEqual(result.text, "打开 Cloud Code。")
        XCTAssertEqual(result.appliedRules.map(\.bundleId), ["com.example.editor"])
    }

    func testExplicitQuickExpansionsRetainOrderPathsAndIdentifierSemantics() {
        let result = SnippetStorage.apply(to: "我的邮箱 /tmp/hello foo_hello_bar",
            globalRules: [("我的邮箱", "person@example.invalid"), ("hello", "world")],
            appRules: [], bundleId: nil)
        XCTAssertEqual(result.text, "person@example.invalid /tmp/world foo_world_bar")
        XCTAssertEqual(result.appliedRules.count, 2)
    }

    func testConfirmationUpdatesAllEquivalentForcedTriggersAndNextInputUsesNewValue() throws {
        let p = Memory()
        p.mappings = [.init(trigger: "Tellme", replacement: "OldTool"), .init(trigger: "Tell Me", replacement: "OtherTool"),
                      .init(trigger: "我的邮箱", replacement: "test@example.invalid")]
        try CorrectionLearningStore(persistence: p).learn(candidate(scope: .hotwordAndMapping))
        XCTAssertEqual(p.mappings.count, 2)
        let output = SnippetStorage.apply(to: "打开 Tell me。", globalRules: p.mappings.map { ($0.trigger, $0.replacement) }, appRules: [], bundleId: nil)
        XCTAssertEqual(output.text, "打开 Type4Me。")
        XCTAssertTrue(p.references.isEmpty)
    }

    func testSoftConfirmationDoesNotOverwriteExistingExplicitShortcut() throws {
        let p = Memory()
        p.mappings = [.init(trigger: "Tellme", replacement: "shortcut")]
        try CorrectionLearningStore(persistence: p).learn(candidate())
        XCTAssertEqual(p.mappings[0].replacement, "shortcut")
        XCTAssertEqual(p.mappingWrites, 0)
    }

    func testEquivalentReferenceConflictAbstains() {
        let refs = [reference("Tell me", "Type4Me"), reference("Tellme", "OtherTool")]
        XCTAssertTrue(VocabularyCorrectionPolicy.select(refs, input: "打开 Tell me。", context: context()).isEmpty)
    }

    func testConfirmReloadNextRequestAndValidatorUseSameEvidence() throws {
        let p = Memory()
        p.words = (0..<20).map { "Unrelated\($0)" }
        try CorrectionLearningStore(persistence: p).learn(candidate())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("references.json")
        try CorrectionReferenceStorage.save(p.references, to: file)
        let reloaded = try CorrectionReferenceStorage.load(from: file)
        let input = "把 Tell me 切换到 2.5 版本。"
        let prompt = IntelliSensePromptBuilder.build(request: .init(text: input, context: context(), settings: .init(),
            personalVocabulary: p.words, correctionReferences: reloaded))
        XCTAssertTrue(prompt.contains("- Type4Me"))
        XCTAssertTrue(prompt.contains("Tell me → Type4Me"))
        let good = "把 Type4Me 切换到 2.5 版本。"
        XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: good, context: context(), correctionReferences: reloaded).finalText, good)
        for bad in ["把 Type4Me 切换到 2.6 版本。", "把 Type4Me 切换到 2.5 版本，费用 500 元。"] {
            XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: bad, context: context(), correctionReferences: reloaded).finalText, input)
        }
    }

    func testHotwordOnlyNeverManufacturesAConfirmedPair() throws {
        let p = Memory()
        try CorrectionLearningStore(persistence: p).learn(candidate(scope: .hotwordOnly))
        XCTAssertEqual(p.words, ["Type4Me"])
        XCTAssertTrue(p.references.isEmpty)
        XCTAssertTrue(p.mappings.isEmpty)
    }

    func testDifferentASRSpellingsNeedEvidenceAndCanShareCanonicalName() throws {
        let p = Memory(), store: CorrectionLearningStore
        store = CorrectionLearningStore(persistence: p)
        try store.learn(candidate())
        XCTAssertTrue(VocabularyCorrectionPolicy.select(p.references, input: "打开 TapForMe。", context: context()).isEmpty)
        try store.learn(candidate("TapForMe"))
        XCTAssertEqual(p.words, ["Type4Me"])
        XCTAssertEqual(VocabularyCorrectionPolicy.select(p.references, input: "打开 TapForMe。", context: context()).map(\.correctedText), ["Type4Me"])
    }

    func testAppReferencesRemainLocalUntilExplicitSharedConfirmation() throws {
        let p = Memory(); let store = CorrectionLearningStore(persistence: p)
        try store.learn(candidate())
        XCTAssertTrue(VocabularyCorrectionPolicy.select(p.references, input: "打开 Tell me。", context: context("com.example.other")).isEmpty)
        try store.learn(candidate(scope: .sharedReference))
        XCTAssertEqual(VocabularyCorrectionPolicy.select(p.references, input: "打开 Tell me。", context: context("com.example.other")).count, 1)
        for availability in [ContextAvailability.blacklisted, .sensitive] {
            XCTAssertTrue(VocabularyCorrectionPolicy.select(p.references, input: "打开 Tell me。", context: context("com.example.other", availability)).isEmpty)
            let prompt = IntelliSensePromptBuilder.build(request: .init(text: "打开 Tell me。", context: context("com.example.other", availability), settings: .init(), personalVocabulary: p.words, correctionReferences: p.references))
            XCTAssertFalse(prompt.contains("<personal_vocabulary>"))
            XCTAssertFalse(prompt.contains("<confirmed_spelling_references>"))
        }
    }

    func testExplicitLocalReferenceWinsOverSharedReferenceButLocalConflictAbstains() {
        var refs = [reference("Tell me", "SharedTool", shared: true), reference("tellme", "LocalTool")]
        XCTAssertEqual(VocabularyCorrectionPolicy.select(refs, input: "打开 Tell me。", context: context()).map(\.correctedText), ["LocalTool"])
        refs.append(reference("Tell Me", "ConflictingLocal"))
        XCTAssertTrue(VocabularyCorrectionPolicy.select(refs, input: "打开 Tell me。", context: context()).isEmpty)
    }

    func testOldReferenceJSONRemainsLocalAndNewFieldIsOptional() throws {
        let original = reference("Tell me", "Type4Me")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "sharedAcrossApps")
        let decoded = try JSONDecoder().decode(VocabularyCorrectionReference.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.sharedAcrossApps)
        XCTAssertTrue(VocabularyCorrectionPolicy.select([decoded], input: "打开 Tell me。", context: context("com.example.other")).isEmpty)
    }

    func testUnrelatedTermsDoNotStarveRelevantNewNameWithinSameBudget() {
        let words = (0..<30).map { "Unrelated\($0)" } + ["FutureTool"]
        let selection = IntelliSensePromptBuilder.selectPersonalVocabulary(words, text: "打开 Future Tool。")
        XCTAssertEqual(selection.terms.first, "FutureTool")
        XCTAssertEqual(selection.includedIndices.first, 30)
        XCTAssertEqual(selection.terms.count, 20)
        XCTAssertLessThanOrEqual(selection.terms.joined().count, 400)
    }

    func testSelectionDoesNotPretendToKnowUnconfirmedAcousticAliases() {
        let words = (0..<20).map { "Unrelated\($0)" } + ["FutureTool"]
        XCTAssertFalse(IntelliSensePromptBuilder.selectPersonalVocabulary(words, text: "打开完全不同的错写。").terms.contains("FutureTool"))
    }

    func testSensitiveTermsStayExcludedEvenWhenPreferred() {
        let unsafe = "api_key = synthetic-canary"
        let selection = IntelliSensePromptBuilder.selectPersonalVocabulary([unsafe, "Type4Me"], text: unsafe, preferredSpellings: [unsafe])
        XCTAssertEqual(selection.terms, ["Type4Me"])
        XCTAssertEqual(selection.excludedIndicesByReason["sensitive"], [0])
    }

    func testBadCandidatesCannotRewriteQuotedNamesOrIdentifiers() {
        for (input, bad) in [("引用“Cortex”。", "引用“Codex”。"), ("引用\"Cortex\"。", "引用\"Codex\"。"),
                             ("foo_Codec_bar", "foo_Codex_bar"), ("`Cortex`", "`Codex`"),
                             ("/tmp/Cortex/config.json", "/tmp/Codex/config.json")] {
            XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: bad, context: context(), correctionReferences: [reference("Cortex", "Codex")]).finalText, input)
        }
    }

    func testQuoteStyleCanChangeWithoutChangingQuotedContent() {
        let result = IntelliSenseOutputValidator.process(input: "引用\"Cortex\"。", candidate: "引用“Cortex”。")
        XCTAssertEqual(result.finalText, "引用“Cortex”。")
    }

    func testSimpleNegationErasureRejectedWithoutBanningParaphrases() {
        for (input, bad) in [("我不使用这个功能。", "我使用这个功能。"), ("我没有提交。", "我提交。"),
                             ("I do not use it.", "I do use it.")] {
            XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: bad).finalText, input)
        }
        let input = "我没有提交。", paraphrase = "我尚未提交。"
        XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: paraphrase).finalText, paraphrase)
    }

    func testLegitimateNamesAndNumbersArePreserved() {
        for input in ["请用 Typeform 制作表单。", "这是 Tableau 的教程。", "这里的 Cortex 指 CPU 内核，不是 Codex。",
                      "Cloud Code 是原文的产品名，请保留。", "Tell me what happened.", "这个视频使用 H.264 Codec。",
                      "预算是 1200 元，不要改成 1500 元。", "我不使用这个功能。", "引用“Cortex”。", "foo_Codec_bar"] {
            XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: input, context: context(), correctionReferences: [reference("Cortex", "Codex")]).finalText, input)
        }
    }

    func testCanonicalRenameUpdatesHotwordAndReferencesButNotQuickExpansions() throws {
        let p = Memory(); let store = CorrectionLearningStore(persistence: p)
        try store.learn(candidate())
        p.mappings = [.init(trigger: "展开", replacement: "Type4Me 固定文本")]
        try store.renameCanonical("Type4Me", to: "TypeForMe")
        XCTAssertEqual(p.words, ["TypeForMe"])
        XCTAssertEqual(p.references.map(\.correctedText), ["TypeForMe"])
        XCTAssertEqual(p.mappings.first?.replacement, "Type4Me 固定文本")
        XCTAssertEqual(VocabularyCorrectionPolicy.select(p.references, input: "打开 Tell me。", context: context()).first?.correctedText, "TypeForMe")
    }

    func testFailedBatchRollsBackAndDoesNotTriggerHotwordSync() throws {
        let p = Memory(); p.failNextReferenceSave = true
        XCTAssertThrowsError(try CorrectionLearningStore(persistence: p).learn(candidate()))
        XCTAssertTrue(p.words.isEmpty)
        XCTAssertTrue(p.references.isEmpty)
        XCTAssertEqual(p.syncs, 0)
    }

    func testConflictingForcedBatchIsRejectedBeforeAnyWrite() {
        let p = Memory()
        XCTAssertThrowsError(try CorrectionLearningStore(persistence: p).learn([
            candidate(scope: .hotwordAndMapping), candidate("Tellme", "OtherTool", scope: .hotwordAndMapping)
        ]))
        XCTAssertEqual(p.totalWrites, 0)
        XCTAssertEqual(p.syncs, 0)
    }

    func testDuplicateReferenceReturnsAlreadyKnownWithoutExtraWrites() throws {
        let p = Memory(); let store = CorrectionLearningStore(persistence: p)
        XCTAssertEqual(try store.learn(candidate()), .saved)
        let writes = p.totalWrites
        XCTAssertEqual(try store.learn(candidate("tellme", "type4me")), .alreadyKnown)
        XCTAssertEqual(p.totalWrites, writes)
    }

    func testDeletingCanonicalNameRemovesAssociatedReferencesNotQuickExpansions() throws {
        let p = Memory(); let store = CorrectionLearningStore(persistence: p)
        try store.learn(candidate())
        p.mappings = [.init(trigger: "展开", replacement: "Type4Me 固定文本")]
        try store.removeCanonical("type4me")
        XCTAssertTrue(p.words.isEmpty)
        XCTAssertTrue(p.references.isEmpty)
        XCTAssertEqual(p.mappings.count, 1)
    }

    private final class Memory: CorrectionVocabularyPersisting {
        var words: [String] = []
        var mappings: [CorrectionMapping] = []
        var references: [VocabularyCorrectionReference] = []
        var totalWrites = 0, mappingWrites = 0, syncs = 0
        var failNextReferenceSave = false
        func loadHotwords() -> [String] { words }
        func loadMappings() -> [CorrectionMapping] { mappings }
        func loadReferences() throws -> [VocabularyCorrectionReference] { references }
        func saveHotwords(_ words: [String]) throws { totalWrites += 1; self.words = words }
        func saveMappings(_ mappings: [CorrectionMapping]) throws { totalWrites += 1; mappingWrites += 1; self.mappings = mappings }
        func saveReferences(_ references: [VocabularyCorrectionReference]) throws {
            totalWrites += 1
            if failNextReferenceSave { failNextReferenceSave = false; throw NSError(domain: "synthetic-failure", code: 1) }
            self.references = references
        }
        func didCommitHotwords() { syncs += 1 }
    }
}
