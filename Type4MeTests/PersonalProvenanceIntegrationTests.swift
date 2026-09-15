import Foundation
import XCTest
import Type4MeIntelliSenseCore
@testable import Type4Me

/// Synthetic integration controls. No ASR, network, AX, real profile, or clipboard.
final class PersonalProvenanceIntegrationTests: XCTestCase {
    func testFinalDestinationUnifiesSnippetProvenanceAndPersonalReference() async throws {
        let client = ProvenanceLLMClient(output: "文档 中把 Type4Me 切换到 2.5 版本。")
        let output = await switchingCase(client: client, finalHasRule: true)
        let result = try XCTUnwrap(output)
        let pass = try XCTUnwrap(result.snippets)
        let calls = await client.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.text, "文档 中把 Tell me 切换到 2.5 版本。")
        XCTAssertEqual(pass.text, "文档 中把 Tell me 切换到 2.5 版本。")
        XCTAssertEqual(pass.appliedRules, [
            AppliedSnippetRule(trigger: "Doc", value: "文档", bundleId: "com.example.final")
        ])
        XCTAssertEqual(result.text, "文档 中把 Type4Me 切换到 2.5 版本。")
        XCTAssertTrue(calls.first?.prompt.contains("<personal_vocabulary>") == true)
        XCTAssertTrue(calls.first?.prompt.contains("<confirmed_spelling_references>") == true)
        XCTAssertFalse(calls.first?.prompt.contains("OtherBrand") == true)
        XCTAssertTrue(result.trace?.contains("com.example.final") == true)
    }

    func testIntegratedReferenceNeverPermitsVersionChange() async throws {
        let client = ProvenanceLLMClient(output: "文档 中把 Type4Me 切换到 2.6 版本。")
        let output = await switchingCase(client: client, finalHasRule: true)
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.text, "文档 中把 Tell me 切换到 2.5 版本。")
        XCTAssertEqual(result.snippets?.text, result.text)
        XCTAssertTrue(result.trace?.contains("protectedResultFallback") == true)
        let calls = await client.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func testSwitchToNoRulesClearsProvenanceWithoutLosingPersonalReference() async throws {
        let client = ProvenanceLLMClient(output: "Doc 中把 Type4Me 切换到 2.5 版本。")
        let output = await switchingCase(client: client, finalHasRule: false)
        let result = try XCTUnwrap(output)
        let pass = try XCTUnwrap(result.snippets)
        XCTAssertEqual(pass.text, "Doc 中把 Tell me 切换到 2.5 版本。")
        XCTAssertTrue(pass.appliedRules.isEmpty)
        XCTAssertEqual(result.text, "Doc 中把 Type4Me 切换到 2.5 版本。")
        let calls = await client.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls.first?.prompt.contains("<confirmed_spelling_references>") == true)
    }

    func testSensitiveDestinationOmitsPersonalEvidenceAndDisablesObservation() async throws {
        let destination = provenanceTarget("com.example.processing", pid: 8102)
        let snapshot = provenanceSnapshot(destination, availability: .sensitive)
        let input = "把 Tell me 切换到 2.5 版本。"
        let client = ProvenanceLLMClient(output: input)
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        let output = await session.processIntelliSenseForTesting(
            text: input,
            startingSnapshot: provenanceSnapshot(provenanceTarget("com.example.start", pid: 8101)),
            settings: provenanceSettings(),
            personalVocabulary: ["SyntheticPrivateTerm"],
            correctionReferences: [provenanceReference(bundle: destination.bundleIdentifier!)],
            currentTarget: { destination }, capture: { _, _ in snapshot }
        )
        let result = try XCTUnwrap(output)
        XCTAssertEqual(result.contextAvailability, .sensitive)
        XCTAssertFalse(result.shouldTrackLearning)
        XCTAssertFalse(result.learningPlan.correctionEnabled)
        XCTAssertFalse(result.learningPlan.expressionLearningEnabled)
        let calls = await client.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls.first?.prompt.contains("SyntheticPrivateTerm") == true)
        XCTAssertFalse(calls.first?.prompt.contains("<confirmed_spelling_references>") == true)
    }

    func testLateReceiverSwitchKeepsProcessingEvidenceAndOneRequest() async throws {
        let processing = provenanceTarget("com.example.processing", pid: 8202)
        let receiver = provenanceTarget("com.example.receiver", pid: 8203)
        let current = ProvenanceTargetBox(processing)
        let client = ProvenanceLLMClient(output: "把 Type4Me 切换到 2.5 版本。") { current.set(receiver) }
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        let output = await session.processIntelliSenseForTesting(
            text: "把 Tell me 切换到 2.5 版本。",
            startingSnapshot: provenanceSnapshot(provenanceTarget("com.example.start", pid: 8201)),
            settings: provenanceSettings(), personalVocabulary: ["Type4Me"],
            correctionReferences: [provenanceReference(bundle: processing.bundleIdentifier!)],
            currentTarget: { current.value() }, capture: { target, _ in provenanceSnapshot(target) }
        )
        let result = try XCTUnwrap(output)
        let calls = await client.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(result.text, "把 Type4Me 切换到 2.5 版本。")
        XCTAssertTrue(result.trace?.contains("com.example.processing") == true)
        XCTAssertFalse(result.trace?.contains("com.example.receiver") == true)
        XCTAssertNil(result.contextAvailability)
    }

    func testTrackerAndDiagnosticCallbackShareOverridesAndChainedMatches() {
        var events: [String] = []
        let pass = SnippetStorage.apply(
            to: "Echo Doc", globalRules: [("Doc", "Docker"), ("Echo", "Doc")],
            appRules: [("Doc", "文档")], bundleId: "com.example.final"
        ) { scope, index, count in
            events.append("\(scope):\(index):\(count)")
        }
        XCTAssertEqual(pass.text, "文档 文档")
        XCTAssertEqual(events, ["global:1:1", "app:0:2"])
        XCTAssertEqual(pass.appliedRules, [
            AppliedSnippetRule(trigger: "Echo", value: "Doc", bundleId: nil),
            AppliedSnippetRule(trigger: "Doc", value: "文档", bundleId: "com.example.final")
        ])
    }

    func testIntegratedPassCanRoundTripWithoutAttributingLLMEditToSnippet() async throws {
        let client = ProvenanceLLMClient(output: "文档 中把 Type4Me 切换到 2.5 版本。")
        let output = await switchingCase(client: client, finalHasRule: true)
        let result = try XCTUnwrap(output)
        let pass = try XCTUnwrap(result.snippets)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(path: directory.appendingPathComponent("history.db").path)
        // Explicit temporary persistence of the real pipeline result. This does
        // not exercise the production clipboard/history-write tail of the session.
        await store.insert(HistoryRecord(
            id: "synthetic-provenance", createdAt: Date(), durationSeconds: 1,
            rawText: "Doc 中把 Tell me 切换到 2.5 版本。", processingMode: "synthetic",
            processedText: result.text, finalText: result.text, status: "completed",
            characterCount: result.text.count, asrProvider: "synthetic",
            postSnippetText: pass.text, appliedSnippets: pass.appliedRules
        ))
        let records = await store.fetchAll()
        let saved = try XCTUnwrap(records.first { $0.id == "synthetic-provenance" })
        XCTAssertEqual(saved.postSnippetText, "文档 中把 Tell me 切换到 2.5 版本。")
        XCTAssertEqual(saved.finalText, "文档 中把 Type4Me 切换到 2.5 版本。")
        XCTAssertEqual(saved.appliedSnippets, pass.appliedRules)
    }

    func testBackupLocationsFollowActiveBuildNamespace() {
        XCTAssertEqual(DataBackupManager.dataDirectory.lastPathComponent, AppDataNamespace.directoryName)
        XCTAssertEqual(DataBackupManager.backupRoot.lastPathComponent, AppDataNamespace.directoryName + " Backups")
        XCTAssertEqual(DataBackupManager.dataDirectory.deletingLastPathComponent(), DataBackupManager.backupRoot.deletingLastPathComponent())
        #if TYPE4ME_PERSONAL_BUILD && !TYPE4ME_DEV_BUILD
        XCTAssertEqual(DataBackupManager.dataDirectory.lastPathComponent, "Type4Me Personal")
        XCTAssertEqual(DataBackupManager.backupRoot.lastPathComponent, "Type4Me Personal Backups")
        #else
        XCTAssertEqual(DataBackupManager.dataDirectory.lastPathComponent, "Type4Me")
        XCTAssertEqual(DataBackupManager.backupRoot.lastPathComponent, "Type4Me Backups")
        #endif
    }

    func testBackupPreservesReferencesAndNeverIncludesSiblingProfile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let personal = directory.appendingPathComponent("Type4Me Personal", isDirectory: true)
        let sibling = directory.appendingPathComponent("Type4Me", isDirectory: true)
        let backups = directory.appendingPathComponent("Type4Me Personal Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let sentinel = sibling.appendingPathComponent("credentials.json")
        try Data("synthetic-sibling-do-not-import".utf8).write(to: sentinel)
        let reference = provenanceReference(bundle: "com.example.final")
        try CorrectionReferenceStorage.save([reference], to: personal.appendingPathComponent("correction-references.json"))
        let snapshot = try XCTUnwrap(try DataBackupManager.snapshot(
            now: Date(timeIntervalSince1970: 1_800_000_000), from: personal, root: backups
        ))
        let restored = try CorrectionReferenceStorage.load(from: snapshot.appendingPathComponent("correction-references.json"))
        XCTAssertEqual(restored, [reference])
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("credentials.json").path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("synthetic-sibling-do-not-import".utf8))
    }

    private func switchingCase(client: ProvenanceLLMClient, finalHasRule: Bool) async -> RecognitionSession.IntelliSenseOutputForTesting? {
        let processing = provenanceTarget("com.example.processing", pid: 8002)
        let destination = provenanceTarget("com.example.final", pid: 8003)
        let current = ProvenanceTargetBox(processing)
        let session = RecognitionSession()
        await session.setInjectedLLMClientForTesting(client)
        return await session.processIntelliSenseForTesting(
            text: "Doc 中把 Tell me 切换到 2.5 版本。",
            startingSnapshot: provenanceSnapshot(provenanceTarget("com.example.start", pid: 8001)),
            settings: provenanceSettings(), personalVocabulary: ["Type4Me"],
            correctionReferences: [
                provenanceReference(bundle: processing.bundleIdentifier!, canonical: "OtherBrand"),
                provenanceReference(bundle: destination.bundleIdentifier!)
            ],
            applySnippets: { text, bundle in
                let rules: [(trigger: String, value: String)]
                if bundle == processing.bundleIdentifier { rules = [("Doc", "Docker")] }
                else { rules = finalHasRule ? [("Doc", "文档"), ("Docker", "重复替换错误")] : [] }
                return SnippetStorage.apply(to: text, globalRules: [], appRules: rules, bundleId: bundle)
            },
            currentTarget: { current.value() },
            capture: { target, _ in current.set(destination); return provenanceSnapshot(target) }
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("personal-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func provenanceReference(bundle: String, canonical: String = "Type4Me") -> VocabularyCorrectionReference {
    VocabularyCorrectionReference(wrongText: "Tell me", correctedText: canonical, bundleIdentifier: bundle, sourceRecordID: "synthetic-reference", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
}

private func provenanceTarget(_ bundle: String, pid: pid_t) -> TargetApplicationContext {
    TargetApplicationContext(processIdentifier: pid, bundleIdentifier: bundle, displayName: bundle)
}

private func provenanceSnapshot(_ target: TargetApplicationContext, availability: ContextAvailability = .appAndControl) -> IntelliSenseContextSnapshot {
    IntelliSenseContextSnapshot(bundleIdentifier: target.bundleIdentifier, appName: target.displayName, appCategory: .other, controlCategory: .multiLine, contextBeforeCursor: "", contextAfterCursor: "", availability: availability, wasTruncated: false)
}

private func provenanceSettings() -> IntelliSenseSettings {
    IntelliSenseSettings(applicationAwarenessEnabled: true, contextAwarenessEnabled: true, correctionDetectionEnabled: true, expressionLearningEnabled: true)
}

private final class ProvenanceTargetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var target: TargetApplicationContext
    init(_ target: TargetApplicationContext) { self.target = target }
    func value() -> TargetApplicationContext { lock.lock(); defer { lock.unlock() }; return target }
    func set(_ target: TargetApplicationContext) { lock.lock(); defer { lock.unlock() }; self.target = target }
}

private actor ProvenanceLLMClient: LLMClient {
    struct Call: Sendable { let text: String; let prompt: String }
    private let output: String
    private let afterProcess: (@Sendable () -> Void)?
    private var recorded: [Call] = []
    init(output: String, afterProcess: (@Sendable () -> Void)? = nil) { self.output = output; self.afterProcess = afterProcess }
    func process(text: String, prompt: String, config: LLMConfig, inputBoundary: LLMInputBoundary) async throws -> String {
        recorded.append(Call(text: text, prompt: prompt)); afterProcess?(); return output
    }
    func calls() -> [Call] { recorded }
    func warmUp(baseURL: String) async {}
    func invalidate() async {}
}
