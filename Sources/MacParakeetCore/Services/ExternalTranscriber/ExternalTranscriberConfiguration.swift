import Foundation

/// User settings for the external meeting transcriber: a shell command that
/// replaces built-in meeting STT and diarization (ADR-035). Disabled by
/// default. Commands read their inputs from environment variables only.
public struct ExternalTranscriberConfiguration: Sendable, Equatable {
    public static let enabledKey = "externalTranscriberEnabled"
    public static let commandKey = "externalTranscriberCommand"
    public static let applyCommandKey = "externalTranscriberApplyCommand"
    public static let timeoutSecondsKey = "externalTranscriberTimeoutSeconds"
    public static let defaultTimeoutSeconds: TimeInterval = 1800
    public static let minimumTimeoutSeconds: TimeInterval = 60
    public static let maximumTimeoutSeconds: TimeInterval = 14_400

    /// Folder inside the meeting folder that the command writes into.
    public static let outputFolderName = "external-transcript"

    public var enabled: Bool
    public var command: String
    /// Runs after a speaker is named in MacParakeet; blank disables write-back.
    public var applyCommand: String
    public var timeoutSeconds: TimeInterval

    public init(
        enabled: Bool = false,
        command: String = "",
        applyCommand: String = "",
        timeoutSeconds: TimeInterval = Self.defaultTimeoutSeconds
    ) {
        self.enabled = enabled
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.applyCommand = applyCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timeoutSeconds = Self.clampedTimeout(timeoutSeconds)
    }

    /// Enabled with a command to run.
    public var isActive: Bool { enabled && !command.isEmpty }

    public var writesBackNames: Bool { !applyCommand.isEmpty }

    public static func current(defaults: UserDefaults = .standard) -> ExternalTranscriberConfiguration {
        ExternalTranscriberConfiguration(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? false,
            command: defaults.string(forKey: commandKey) ?? "",
            applyCommand: defaults.string(forKey: applyCommandKey) ?? "",
            timeoutSeconds: defaults.object(forKey: timeoutSecondsKey) as? Double ?? defaultTimeoutSeconds
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(command, forKey: Self.commandKey)
        defaults.set(applyCommand, forKey: Self.applyCommandKey)
        defaults.set(timeoutSeconds, forKey: Self.timeoutSecondsKey)
    }

    /// Recorded in `Transcription.engine` for transcripts the command produced.
    public static let engineName = "external"

    /// First word of the command, recorded as the engine variant.
    public var commandName: String? {
        command.split(whereSeparator: \.isWhitespace).first.map { (String($0) as NSString).lastPathComponent }
    }

    public static func clampedTimeout(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimumTimeoutSeconds), maximumTimeoutSeconds)
    }

    public static func outputFolder(inMeetingFolder folderURL: URL) -> URL {
        folderURL.appendingPathComponent(outputFolderName, isDirectory: true)
    }
}

/// Ready-made commands for supported tools.
public enum ExternalTranscriberPreset: String, CaseIterable, Sendable {
    case paraspeakrs

    public var displayName: String {
        switch self {
        case .paraspeakrs: return "paraspeakrs"
        }
    }

    public var command: String {
        switch self {
        case .paraspeakrs:
            // fp32 avoids paraspeakrs's interactive precision question on a first run.
            return
                #"paraspeakrs agent transcribe "$MACPARAKEET_AUDIO" -o "$MACPARAKEET_OUT_DIR" --sherpa-precision fp32"#
        }
    }

    public var applyCommand: String {
        switch self {
        case .paraspeakrs:
            return #"paraspeakrs agent apply "$MACPARAKEET_OUT_DIR""#
        }
    }
}
