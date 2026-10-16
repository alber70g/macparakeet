import Foundation
import OSLog

public protocol ExternalTranscriberRunning: Sendable {
    /// Runs the transcribe command into a fresh output folder and reads its
    /// `transcript.json`.
    func transcribe(
        audioURL: URL,
        outputFolder: URL,
        meetingID: UUID,
        configuration: ExternalTranscriberConfiguration
    ) async throws -> ExternalTranscript

    /// Runs the apply command on an existing output folder.
    func apply(
        outputFolder: URL,
        meetingID: UUID,
        configuration: ExternalTranscriberConfiguration
    ) async throws
}

public enum ExternalTranscriberError: Error, LocalizedError, Equatable {
    case notConfigured
    case commandFailed(String)
    case timedOut(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The external transcriber command is not configured."
        case .commandFailed(let detail):
            return "The external transcriber failed: \(detail)"
        case .timedOut(let seconds):
            return "The external transcriber did not finish within \(seconds) seconds."
        }
    }
}

public final class ExternalTranscriberRunner: ExternalTranscriberRunning {
    public static let audioEnvironmentKey = "MACPARAKEET_AUDIO"
    public static let outputEnvironmentKey = "MACPARAKEET_OUT_DIR"
    public static let meetingEnvironmentKey = "MACPARAKEET_MEETING_ID"
    /// Error text keeps the end of stderr, where tools print the failure.
    static let stderrTailLineCount = 12

    private let executor: LocalCLIExecutor
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "ExternalTranscriber")

    public init(executor: LocalCLIExecutor = LocalCLIExecutor()) {
        self.executor = executor
    }

    public func transcribe(
        audioURL: URL,
        outputFolder: URL,
        meetingID: UUID,
        configuration: ExternalTranscriberConfiguration
    ) async throws -> ExternalTranscript {
        guard !configuration.command.isEmpty else { throw ExternalTranscriberError.notConfigured }
        // The folder is MacParakeet-owned output of an earlier attempt; tools
        // such as paraspeakrs require it to be new or empty.
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputFolder.path) {
            try fileManager.removeItem(at: outputFolder)
        }
        try fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        try await run(
            configuration.command,
            environment: [
                Self.audioEnvironmentKey: audioURL.path,
                Self.outputEnvironmentKey: outputFolder.path,
                Self.meetingEnvironmentKey: meetingID.uuidString,
            ],
            timeout: configuration.timeoutSeconds
        )
        return try ExternalTranscript.load(fromFolder: outputFolder)
    }

    public func apply(
        outputFolder: URL,
        meetingID: UUID,
        configuration: ExternalTranscriberConfiguration
    ) async throws {
        guard configuration.writesBackNames else { throw ExternalTranscriberError.notConfigured }
        try await run(
            configuration.applyCommand,
            environment: [
                Self.outputEnvironmentKey: outputFolder.path,
                Self.meetingEnvironmentKey: meetingID.uuidString,
            ],
            timeout: configuration.timeoutSeconds
        )
    }

    private func run(_ command: String, environment: [String: String], timeout: TimeInterval) async throws {
        let startedAt = Date()
        do {
            _ = try await executor.runCommand(command, environment: environment, timeout: timeout)
            logger.info("external_transcriber_command_completed duration_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000), privacy: .public)")
        } catch let error as LocalCLIError {
            logger.error("external_transcriber_command_failed error=\(error.localizedDescription, privacy: .private)")
            switch error {
            case .timeout(let seconds):
                throw ExternalTranscriberError.timedOut(seconds: Int(seconds))
            case .nonZeroExit(let code, let stderr):
                let tail = Self.tail(of: stderr)
                throw ExternalTranscriberError.commandFailed(
                    tail.isEmpty ? "exit code \(code)" : "exit code \(code): \(tail)"
                )
            default:
                throw ExternalTranscriberError.commandFailed(error.localizedDescription)
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
