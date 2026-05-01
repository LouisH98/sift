import Foundation

enum ShellEnvironmentReaderError: LocalizedError {
    case invalidEnvironmentVariableName
    case unsupportedShell(String)
    case shellLaunchFailed
    case shellTimedOut
    case shellFailed(String)
    case missingValue(String)
    case unreadableOutput

    var errorDescription: String? {
        switch self {
        case .invalidEnvironmentVariableName:
            "Enter a valid environment variable name."
        case .unsupportedShell(let shell):
            "Shell environment reading does not support \(shell)."
        case .shellLaunchFailed:
            "Could not start your login shell."
        case .shellTimedOut:
            "Shell environment read timed out."
        case .shellFailed(let detail):
            detail.isEmpty ? "Shell environment read failed." : "Shell environment read failed: \(detail)"
        case .missingValue(let name):
            "Shell did not return \(name)."
        case .unreadableOutput:
            "Could not read shell output."
        }
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var didResume = false

    nonisolated func resume(_ result: Result<Value, Error>, continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else {
            return
        }

        didResume = true
        continuation.resume(with: result)
    }
}

struct ShellEnvironmentReader {
    enum ShellKind: Equatable {
        case zsh
        case bash
        case fish
        case tcsh
        case sh
        case unsupported
    }

    private static let startMarker = "__SIFT_ENV_START__"
    private static let endMarker = "__SIFT_ENV_END__"

    let shellPath: String
    let timeout: TimeInterval

    init(shellPath: String = Self.loginShellPath(), timeout: TimeInterval = 5) {
        self.shellPath = shellPath
        self.timeout = timeout
    }

    func readValue(named rawName: String) async throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEnvironmentVariableName(name) else {
            throw ShellEnvironmentReaderError.invalidEnvironmentVariableName
        }

        let kind = Self.shellKind(for: shellPath)
        guard kind != .unsupported else {
            throw ShellEnvironmentReaderError.unsupportedShell(shellPath)
        }

        let command = try Self.command(for: name, shellKind: kind)
        let output = try await runShell(arguments: Self.arguments(for: command, shellKind: kind))
        let value = try Self.extractValue(from: output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ShellEnvironmentReaderError.missingValue(name)
        }

        return value
    }

    private func runShell(arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let gate = ContinuationGate<String>()

            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: outputData, encoding: .utf8) else {
                    gate.resume(.failure(ShellEnvironmentReaderError.unreadableOutput), continuation: continuation)
                    return
                }

                guard process.terminationStatus == 0 else {
                    let detail = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    gate.resume(.failure(ShellEnvironmentReaderError.shellFailed(detail)), continuation: continuation)
                    return
                }

                gate.resume(.success(output), continuation: continuation)
            }

            do {
                try process.run()
            } catch {
                gate.resume(.failure(ShellEnvironmentReaderError.shellLaunchFailed), continuation: continuation)
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else {
                    return
                }

                process.terminate()
                gate.resume(.failure(ShellEnvironmentReaderError.shellTimedOut), continuation: continuation)
            }
        }
    }

    static func loginShellPath() -> String {
        guard let shell = getpwuid(getuid())?.pointee.pw_shell else {
            return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }

        return String(cString: shell)
    }

    static func shellKind(for shellPath: String) -> ShellKind {
        switch URL(fileURLWithPath: shellPath).lastPathComponent {
        case "zsh":
            return .zsh
        case "bash":
            return .bash
        case "fish":
            return .fish
        case "tcsh", "csh":
            return .tcsh
        case "sh":
            return .sh
        default:
            return .unsupported
        }
    }

    static func isValidEnvironmentVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first.value == 95 || isASCIIAlpha(first) else {
            return false
        }

        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value == 95 || isASCIIAlpha(scalar) || isASCIIDigit(scalar)
        }
    }

    private static func isASCIIAlpha(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value)
    }

    static func command(for name: String, shellKind: ShellKind) throws -> String {
        guard isValidEnvironmentVariableName(name) else {
            throw ShellEnvironmentReaderError.invalidEnvironmentVariableName
        }

        switch shellKind {
        case .zsh, .bash, .sh:
            return "printf '\\n\(startMarker)%s\(endMarker)\\n' \"$\(name)\""
        case .fish:
            return "set -q \(name); and printf '\\n\(startMarker)%s\(endMarker)\\n' \"$\(name)\"; or printf '\\n\(startMarker)\(endMarker)\\n'"
        case .tcsh:
            return "if ($?\(name)) printf '\\n\(startMarker)%s\(endMarker)\\n' \"$\(name)\"; else printf '\\n\(startMarker)\(endMarker)\\n'; endif"
        case .unsupported:
            throw ShellEnvironmentReaderError.unsupportedShell("")
        }
    }

    static func arguments(for command: String, shellKind: ShellKind) -> [String] {
        switch shellKind {
        case .zsh, .bash:
            return ["-ilc", command]
        case .fish, .tcsh:
            return ["-lic", command]
        case .sh:
            return ["-lc", command]
        case .unsupported:
            return []
        }
    }

    static func extractValue(from output: String) throws -> String {
        guard let startRange = output.range(of: startMarker),
              let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex) else {
            throw ShellEnvironmentReaderError.unreadableOutput
        }

        return String(output[startRange.upperBound..<endRange.lowerBound])
    }
}
