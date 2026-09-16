import XCTest
@testable import Type4Me

final class ASRCredentialValidationTests: XCTestCase {
    func testStepFunBatchDoesNotClaimAccountValidationForEitherAccessMode() async throws {
        for mode in StepFunBatchAccessMode.allCases {
            let config = try XCTUnwrap(StepFunBatchASRConfig(credentials: [
                "apiKey": "constructed-invalid-key",
                "accessMode": mode.rawValue,
            ]))
            let result = try await ASRProviderRegistry.validateCredentials(
                for: .stepfunBatch, config: config, options: ASRRequestOptions()
            )
            XCTAssertEqual(result, .configurationOnly)
        }
    }

    func testOtherBatchProviderWithoutRemoteValidatorAlsoReportsLocalOnly() async throws {
        let config = try XCTUnwrap(OpenAIASRConfig(credentials: ["apiKey": "constructed-invalid-key"]))
        let result = try await ASRProviderRegistry.validateCredentials(
            for: .openai, config: config, options: ASRRequestOptions()
        )
        XCTAssertEqual(result, .configurationOnly)
        // Real custom validators and streaming handshakes must keep their path.
        XCTAssertFalse(ASRProviderRegistry.credentialValidationIsLocalOnly(for: .mimo))
        XCTAssertFalse(ASRProviderRegistry.credentialValidationIsLocalOnly(for: .stepfun))
        XCTAssertFalse(ASRProviderRegistry.credentialValidationIsLocalOnly(for: .volcano))
    }

    func testBatchConfigurationCheckStillRejectsMismatchedConfiguration() async throws {
        let config = try XCTUnwrap(OpenAIASRConfig(credentials: ["apiKey": "constructed-invalid-key"]))
        do {
            _ = try await ASRProviderRegistry.validateCredentials(
                for: .stepfunBatch, config: config, options: ASRRequestOptions()
            )
            XCTFail("A configuration for another provider must not pass a local check")
        } catch {
            XCTAssertEqual(error as? StepFunBatchASRError, .invalidConfig)
        }
    }

    func testLocalOnlyFeedbackChangesLanguageWithoutLosingValidationState() {
        let original = UserDefaults.standard.object(forKey: "tf_language")
        defer {
            if let original { UserDefaults.standard.set(original, forKey: "tf_language") }
            else { UserDefaults.standard.removeObject(forKey: "tf_language") }
        }
        let status = SettingsTestStatus.configurationOnly
        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(status.informationalMessage, "仅检查了本地配置，尚未验证账户权限或余额。")
        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(status.informationalMessage,
                       "Local configuration checked; account access and balance are not verified.")
        XCTAssertNil(SettingsTestStatus.success.informationalMessage)
    }
}
