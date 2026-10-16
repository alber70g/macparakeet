import Foundation
import OSLog

public protocol ExternalDiarizerRunning: Sendable {
    /// Runs the detect command into a fresh output folder and reads its
    /// `diarization.json`.
    func diarize(
        audioURL: URL,
        outputFolder: URL,
        transcriptionID: UUID?,
        configuration: ExternalDiarizerConfiguration
    ) async throws -> ExternalDiarization

    /// Runs the apply command on an existing output folder.
    func apply(
        outputFolder: URL,
        transcriptionID: UUID,
        configuration: ExternalDiarizerConfiguration
    ) async throws
}

public enum ExternalDiarizerError: Error, LocalizedError, Equatable {
    case notConfigured
    case commandFailed(String)
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The external speaker detection command is not configured."
        case .commandFailed(let detail):
            return "External speaker detection failed: \(detail)"
        case .timedOut(let seconds):
            return "External speaker detection did not finish within \(seconds) seconds."
        }
    }
}

public final class ExternalDiarizerRunner: ExternalDiarizerRunning {
    public static let audioEnvironmentKey = "MACPARAKEET_AUDIO"
    public static let outputEnvironmentKey = "MACPARAKEET_OUT_DIR"
    public static let transcriptionEnvironmentKey = "MACPARAKEET_TRANSCRIPTION_ID"
    /// Error text keeps the end of stderr, where tools print the failure.
    static let stderrTailLineCount = 12

    private let executor: LocalCLIExecutor
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "ExternalDiarizer")

    public init(executor: LocalCLIExecutor = LocalCLIExecutor()) {
        self.executor = executor
    }

    public func diarize(
        audioURL: URL,
        outputFolder: URL,
        transcriptionID: UUID?,
        configuration: ExternalDiarizerConfiguration
    ) async throws -> ExternalDiarization {
        guard !configuration.command.isEmpty else { throw ExternalDiarizerError.notConfigured }
        // The folder is MacParakeet-owned output of an earlier run; tools
        // such as paraspeakrs require it to be new or empty.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputFolder.path) {
            try fileManager.removeItem(at: outputFolder)
        }
        try fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        var environment = [
            Self.audioEnvironmentKey: audioURL.path,
            Self.outputEnvironmentKey: outputFolder.path,
        ]
        environment[Self.transcriptionEnvironmentKey] = transcriptionID?.uuidString
        try await run(configuration.command, environment: environment, timeout: configuration.timeoutSeconds)
        return try ExternalDiarization.load(fromFolder: outputFolder)
    }

    public func apply(
        outputFolder: URL,
        transcriptionID: UUID,
        configuration: ExternalDiarizerConfiguration
    ) async throws {
        guard configuration.writesBackNames else { throw ExternalDiarizerError.notConfigured }
        try await run(
            configuration.applyCommand,
            environment: [
                Self.outputEnvironmentKey: outputFolder.path,
                Self.transcriptionEnvironmentKey: transcriptionID.uuidString,
            ],
            timeout: configuration.timeoutSeconds
        )
    }

    private func run(_ command: String, environment: [String: String], timeout: TimeInterval) async throws {
        let startedAt = Date()
        do {
            _ = try await executor.runCommand(command, environment: environment, timeout: timeout)
            logger.info(
                "external_diarizer_command_completed duration_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)"
            )
        } catch let error as LocalCLIError {
            logger.error("external_diarizer_command_failed error=\(error.localizedDescription, privacy: .private)")
            switch error {
            case .timeout(let seconds):
                throw ExternalDiarizerError.timedOut(seconds: Int(seconds))
            case .nonZeroExit(let code, let stderr):
                let tail = Self.tail(of: stderr)
                throw ExternalDiarizerError.commandFailed(
                    tail.isEmpty ? "exit code \(code)" : "exit code \(code): \(tail)"
                )
            default:
                throw ExternalDiarizerError.commandFailed(error.localizedDescription)
            }
        }
    }

    static func tail(of stderr: String) -> String {
        stderr
            .split(whereSeparator: \.isNewline)
            .suffix(stderrTailLineCount)
            .joined(separator: "\n")
    }
}
