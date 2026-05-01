import XCTest
@testable import Sift

@MainActor
final class ShellEnvironmentReaderTests: XCTestCase {
    func testEnvironmentVariableNameValidationAllowsShellSafeNames() {
        XCTAssertTrue(ShellEnvironmentReader.isValidEnvironmentVariableName("OPENAI_API_KEY"))
        XCTAssertTrue(ShellEnvironmentReader.isValidEnvironmentVariableName("_OPENAI_API_KEY_2"))
    }

    func testEnvironmentVariableNameValidationRejectsUnsafeNames() {
        XCTAssertFalse(ShellEnvironmentReader.isValidEnvironmentVariableName(""))
        XCTAssertFalse(ShellEnvironmentReader.isValidEnvironmentVariableName("2OPENAI_API_KEY"))
        XCTAssertFalse(ShellEnvironmentReader.isValidEnvironmentVariableName("OPENAI-API-KEY"))
        XCTAssertFalse(ShellEnvironmentReader.isValidEnvironmentVariableName("OPENAI_API_KEY; echo bad"))
        XCTAssertFalse(ShellEnvironmentReader.isValidEnvironmentVariableName("ÖPENAI_API_KEY"))
    }

    func testShellKindDetectionUsesExecutableName() {
        XCTAssertEqual(ShellEnvironmentReader.shellKind(for: "/bin/zsh"), .zsh)
        XCTAssertEqual(ShellEnvironmentReader.shellKind(for: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertEqual(ShellEnvironmentReader.shellKind(for: "/bin/tcsh"), .tcsh)
        XCTAssertEqual(ShellEnvironmentReader.shellKind(for: "/custom/shell"), .unsupported)
    }

    func testCommandContainsMarkersAndValidatedVariableName() throws {
        let command = try ShellEnvironmentReader.command(for: "OPENAI_API_KEY", shellKind: .zsh)

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

        XCTAssertEqual(try ShellEnvironmentReader.extractValue(from: output), "sk-shell")
    }
}
