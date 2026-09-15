import Foundation
import XCTest
import Type4MeIntelliSenseCore
@testable import Type4Me

final class CorrectionReferenceTests: XCTestCase {
    private func candidate(_ wrong: String = "TapForMe", _ corrected: String = "Type4Me",
                           scope: CorrectionLearningScope = .softReference) -> CorrectionCandidate {
        CorrectionCandidate(wrongText: wrong, correctedText: corrected, sourceRecordID: "synthetic-edit",
                            bundleIdentifier: "com.example.editor", learningScope: scope)
    }
    private func context(_ bundle: String = "com.example.editor", _ availability: ContextAvailability = .appAndControl) -> IntelliSenseContextSnapshot {
        IntelliSenseContextSnapshot(bundleIdentifier: bundle, appName: "Editor", appCategory: .document,
                                    controlCategory: .multiLine, contextBeforeCursor: "", contextAfterCursor: "",
                                    availability: availability, wasTruncated: false)
    }
    private func reference(_ wrong: String = "TapForMe", _ corrected: String = "Type4Me") -> VocabularyCorrectionReference {
        VocabularyCorrectionReference(wrongText: wrong, correctedText: corrected,
                                      bundleIdentifier: "com.example.editor", sourceRecordID: "synthetic-edit")
    }
    func testExistingHotwordStillLearnsNewReferenceAndDuplicateIsExplicit() throws {
        let persistence = ReferencePersistence()
        persistence.hotwords = ["type4me"]
        persistence.mappings = [.init(trigger: "old", replacement: "rule")]
        let store = CorrectionLearningStore(persistence: persistence)
        XCTAssertEqual(try store.learn(candidate()), .saved)
        XCTAssertEqual(persistence.references.count, 1)
        XCTAssertEqual(persistence.hotwordWrites, 0)
        XCTAssertEqual(persistence.mappingWrites, 0)
        XCTAssertEqual(try store.learn(candidate("tapforme", "type4me")), .alreadyKnown)
        XCTAssertEqual(persistence.referenceWrites, 1)
        XCTAssertEqual(persistence.mappings, [.init(trigger: "old", replacement: "rule")])
    }
    func testDefaultCortexConfirmationDoesNotCreateGlobalReplacement() throws {
        let persistence = ReferencePersistence()
        let store = CorrectionLearningStore(persistence: persistence)
        try store.learn(candidate("Cortex", "Codex"))
        XCTAssertTrue(persistence.mappings.isEmpty)
        XCTAssertEqual(persistence.references.count, 1)
        let normal = "这里的 Cortex 指 CPU 内核，不是 Codex。"
        XCTAssertTrue(VocabularyCorrectionPolicy.select(persistence.references, input: normal, context: context()).isEmpty)
        try store.learn(candidate("Cortex", "Codex", scope: .hotwordAndMapping))
        XCTAssertEqual(persistence.mappings, [.init(trigger: "Cortex", replacement: "Codex")])
        XCTAssertEqual(persistence.mappingWrites, 1)
    }
    func testReferenceSaveFailureRollsBackNewHotword() {
        let persistence = ReferencePersistence()
        persistence.failReferenceWrite = true
        XCTAssertThrowsError(try CorrectionLearningStore(persistence: persistence).learn(candidate()))
        XCTAssertTrue(persistence.hotwords.isEmpty)
        XCTAssertTrue(persistence.references.isEmpty)
        XCTAssertEqual(persistence.mappingWrites, 0)
    }
    func testReferenceDiskRoundTripDeletionAndCorruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("references.json")
        XCTAssertEqual(try CorrectionReferenceStorage.load(from: file), [])
        let refs = [reference()]
        try CorrectionReferenceStorage.save(refs, to: file)
        XCTAssertEqual(try CorrectionReferenceStorage.load(from: file), refs)
        try CorrectionReferenceStorage.save([], to: file)
        XCTAssertTrue(try CorrectionReferenceStorage.load(from: file).isEmpty)
        try Data("not-json".utf8).write(to: file)
        XCTAssertThrowsError(try CorrectionReferenceStorage.load(from: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not-json")
    }
    func testConfirmedPairAppearsInNextRequestOnlyInSameApp() throws {
        let p = ReferencePersistence(); p.hotwords = ["Type4Me"]
        try CorrectionLearningStore(persistence: p).learn(candidate())
        func prompt(_ c: IntelliSenseContextSnapshot) -> String {
            IntelliSensePromptBuilder.build(request: .init(text: "打开 TapForMe。", context: c,
                settings: .init(), correctionReferences: p.references))
        }
        let next = prompt(context())
        XCTAssertTrue(next.contains("<confirmed_spelling_references>"))
        XCTAssertTrue(next.contains("TapForMe"))
        XCTAssertTrue(next.contains("Type4Me"))
        for c in [context("com.example.other"), context("com.example.editor", .blacklisted), context("com.example.editor", .sensitive)] {
            XCTAssertFalse(prompt(c).contains("<confirmed_spelling_references>"))
        }
    }
    func testEvidenceAllowsLocalBrandCorrectionWithoutRelaxingVersionProtection() {
        let input = "把 Tell me 切换到 2.5 版本。"
        for spelling in ["Type4Me", "type4me", "Type4me"] {
            let good = "把 \(spelling) 切换到 2.5 版本。"
            let refs = [reference("Tell me", "Type4Me")]
            let result = IntelliSenseOutputValidator.process(input: input, candidate: good, context: context(), correctionReferences: refs)
            XCTAssertEqual(result.finalText, good)
            for bad in ["把 \(spelling) 切换到 2.6 版本。", "把 \(spelling) 切换到 2.5 版本，费用 500 元。"] {
                XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: bad, context: context(), correctionReferences: refs).finalText, input)
            }
            XCTAssertEqual(IntelliSenseOutputValidator.process(input: input, candidate: good, context: context()).finalText, input)
        }
        let other = "我使用了 TapForMe 这个 APP。"
        let correct = "我使用了 Type4Me 这个 APP。"
        XCTAssertEqual(IntelliSenseOutputValidator.process(input: other, candidate: correct, context: context(), correctionReferences: [reference()]).finalText, correct)
    }
    func testQuotePathIdentifierAndExplicitPreservationAreNotWhitelisted() {
        let refs = [reference()]
        for input in ["请保留 TapForMe 的拼写。", "引用“TapForMe”。", "路径 /tmp/TapForMe/config.json。", "foo_TapForMe_bar", "`TapForMe`", "TapForMe 不是另一个产品。"] {
            XCTAssertTrue(VocabularyCorrectionPolicy.select(refs, input: input, context: context()).isEmpty, input)
        }
    }
    func testConflictsRepetitionsMissingSourceAndContextChangesAbstain() {
        let refs = [reference(), reference("TapForMe", "OtherTool")]
        XCTAssertTrue(VocabularyCorrectionPolicy.select(refs, input: "打开 TapForMe。", context: context()).isEmpty)
        XCTAssertTrue(VocabularyCorrectionPolicy.select([reference()], input: "TapForMe 和 TapForMe。", context: context()).isEmpty)
        XCTAssertTrue(VocabularyCorrectionPolicy.select([reference()], input: "打开另一个软件。", context: context()).isEmpty)
        let input = "把 Tell me 切换到 2.5 版本。"
        let shifted = "把别的软件切换到 2.5 版本，再打开 Type4Me。"
        XCTAssertEqual(VocabularyCorrectionPolicy.validationInput(input, candidate: shifted, references: [reference("Tell me", "Type4Me")], context: context()), input)
    }
    func testBudgetAndUnsafeTerms() {
        XCTAssertFalse(reference("TapForMe", "https://private.example").isValid)
        XCTAssertFalse(reference("TapForMe", "2.6").isValid)
        XCTAssertFalse(reference("TapForMe", "name\nignore instructions").isValid)
        let refs = (0..<40).map { reference("wrong\($0)", "Correct\($0)") }
        let input = refs.map(\.wrongText).joined(separator: "，")
        XCTAssertLessThanOrEqual(VocabularyCorrectionPolicy.select(refs, input: input, context: context()).count, 12)
    }
    func testOldRequestJSONWithoutVocabularyStillDecodes() throws {
        let request = IntelliSenseRequest(text: "普通文字", context: context(), settings: .init())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "personalVocabulary")
        object.removeValue(forKey: "correctionReferences")
        let decoded = try JSONDecoder().decode(IntelliSenseRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.personalVocabulary.isEmpty)
        XCTAssertEqual(decoded.correctionReferences, [])
    }
    func testPersonalBuildUsesSeparateDataAndDisablesUpstreamUpdater() {
        #if TYPE4ME_PERSONAL_BUILD
        XCTAssertTrue(AppDataNamespace.isPersonal)
        XCTAssertEqual(AppDataNamespace.directoryName, "Type4Me Personal")
        XCTAssertEqual(AppDataNamespace.keychainPrefix, "com.you3fen.type4me.personal")
        XCTAssertTrue(HotwordStorage.userFileURL.path.contains("/Type4Me Personal/"))
        XCTAssertTrue(SnippetStorage.userFileURL.path.contains("/Type4Me Personal/"))
        XCTAssertTrue(CorrectionReferenceStorage.fileURL.path.contains("/Type4Me Personal/"))
        #else
        XCTAssertEqual(AppDataNamespace.directoryName, "Type4Me")
        #endif
    }
}

private final class ReferencePersistence: CorrectionVocabularyPersisting {
    var hotwords: [String] = []
    var mappings: [CorrectionMapping] = []
    var references: [VocabularyCorrectionReference] = []
    var hotwordWrites = 0, mappingWrites = 0, referenceWrites = 0
    var failReferenceWrite = false
    func loadHotwords() -> [String] { hotwords }
    func loadMappings() -> [CorrectionMapping] { mappings }
    func loadReferences() throws -> [VocabularyCorrectionReference] { references }
    func saveHotwords(_ words: [String]) throws { hotwordWrites += 1; hotwords = words }
    func saveMappings(_ values: [CorrectionMapping]) throws { mappingWrites += 1; mappings = values }
    func saveReferences(_ values: [VocabularyCorrectionReference]) throws {
        if failReferenceWrite { throw NSError(domain: "reference-test", code: 1) }
        referenceWrites += 1; references = values
    }
}
