import XCTest
@testable import Sift

@MainActor
final class ShellEnvironmentImporterTests: XCTestCase {
    func testEnvironmentVariableNameValidationAllowsShellSafeNames() {
        XCTAssertTrue(ShellEnvironmentImporter.isValidEnvironmentVariableName("OPENAI_API_KEY"))
        XCTAssertTrue(ShellEnvironmentImporter.isValidEnvironmentVariableName("_OPENAI_API_KEY_2"))
    }

    func testEnvironmentVariableNameValidationRejectsUnsafeNames() {
        XCTAssertFalse(ShellEnvironmentImporter.isValidEnvironmentVariableName(""))
        XCTAssertFalse(ShellEnvironmentImporter.isValidEnvironmentVariableName("2OPENAI_API_KEY"))
        XCTAssertFalse(ShellEnvironmentImporter.isValidEnvironmentVariableName("OPENAI-API-KEY"))
        XCTAssertFalse(ShellEnvironmentImporter.isValidEnvironmentVariableName("OPENAI_API_KEY; echo bad"))
        XCTAssertFalse(ShellEnvironmentImporter.isValidEnvironmentVariableName("ÖPENAI_API_KEY"))
    }

    func testShellKindDetectionUsesExecutableName() {
        XCTAssertEqual(ShellEnvironmentImporter.shellKind(for: "/bin/zsh"), .zsh)
        XCTAssertEqual(ShellEnvironmentImporter.shellKind(for: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertEqual(ShellEnvironmentImporter.shellKind(for: "/bin/tcsh"), .tcsh)
        XCTAssertEqual(ShellEnvironmentImporter.shellKind(for: "/custom/shell"), .unsupported)
    }

    func testCommandContainsMarkersAndValidatedVariableName() throws {
        let command = try ShellEnvironmentImporter.command(for: "OPENAI_API_KEY", shellKind: .zsh)

        XCTAssertTrue(command.contains("__SIFT_ENV_START__"))
        XCTAssertTrue(command.contains("__SIFT_ENV_END__"))
        XCTAssertTrue(command.contains("$OPENAI_API_KEY"))
    }

    func testExtractValueIgnoresNoisyShellOutput() throws {
        let output = """
        Last login: now
        __SIFT_ENV_START__sk-shell__SIFT_ENV_END__
        Prompt text
        """

        XCTAssertEqual(try ShellEnvironmentImporter.extractValue(from: output), "sk-shell")
    }
}
