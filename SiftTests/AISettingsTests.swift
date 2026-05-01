import XCTest
@testable import Sift

@MainActor
final class AISettingsTests: XCTestCase {
    func testResolvedAPIKeyUsesManualKey() {
        let key = AISettings.resolvedAPIKey(
            source: .manual,
            manualAPIKey: " sk-manual ",
            environmentVariableName: "OPENAI_API_KEY",
            environment: ["OPENAI_API_KEY": "sk-env"]
        )

        XCTAssertEqual(key, "sk-manual")
    }

    func testResolvedAPIKeyUsesNamedEnvironmentVariable() {
        let key = AISettings.resolvedAPIKey(
            source: .environmentVariable,
            manualAPIKey: "sk-manual",
            environmentVariableName: " CUSTOM_OPENAI_KEY ",
            environment: ["CUSTOM_OPENAI_KEY": " sk-env "]
        )

        XCTAssertEqual(key, "sk-env")
    }

    func testResolvedAPIKeyReturnsEmptyStringForMissingEnvironmentVariable() {
        let key = AISettings.resolvedAPIKey(
            source: .environmentVariable,
            manualAPIKey: "sk-manual",
            environmentVariableName: "OPENAI_API_KEY",
            environment: [:]
        )

        XCTAssertEqual(key, "")
    }
}
