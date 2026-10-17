import Foundation

/// User settings for the external speaker detector: a shell command that
/// replaces the built-in diarizer (ADR-035). Disabled by default. Commands
/// read their inputs from environment variables only.
public struct ExternalDiarizerConfiguration: Sendable, Equatable {
    public static let enabledKey = "externalDiarizerEnabled"
    public static let commandKey = "externalDiarizerCommand"
    public static let applyCommandKey = "externalDiarizerApplyCommand"
    public static let timeoutSecondsKey = "externalDiarizerTimeoutSeconds"
    public static let defaultTimeoutSeconds: TimeInterval = 1800
    public static let minimumTimeoutSeconds: TimeInterval = 60
    public static let maximumTimeoutSeconds: TimeInterval = 14_400

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

    /// First word of the command, shown where the active detector is named.
    public var commandName: String? {
        command.split(whereSeparator: \.isWhitespace).first.map { (String($0) as NSString).lastPathComponent }
    }

    public static func current(defaults: UserDefaults = .standard) -> ExternalDiarizerConfiguration {
        ExternalDiarizerConfiguration(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? false,
            command: defaults.string(forKey: commandKey) ?? "",
            applyCommand: defaults.string(forKey: applyCommandKey) ?? "",
            timeoutSeconds: defaults.object(forKey: timeoutSecondsKey) as? Double ?? defaultTimeoutSeconds
        )
    }

    /// The preferences the running process shares with the Settings window:
    /// the app's own domain inside an app bundle (including the CLI embedded
    /// in it), the shared MacParakeet suite for a standalone CLI.
    public static func liveDefaults(bundleURL: URL = Bundle.main.bundleURL) -> UserDefaults {
        bundleURL.pathExtension == "app" ? .standard : AppPaths.sharedAppDefaults()
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(command, forKey: Self.commandKey)
        defaults.set(applyCommand, forKey: Self.applyCommandKey)
        defaults.set(timeoutSeconds, forKey: Self.timeoutSecondsKey)
    }

    public static func clampedTimeout(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimumTimeoutSeconds), maximumTimeoutSeconds)
    }
}

/// Ready-made commands for supported tools.
public enum ExternalDiarizerPreset: String, CaseIterable, Sendable {
    case paraspeakrs

    public var displayName: String {
        switch self {
        case .paraspeakrs: return "paraspeakrs"
        }
    }

    public var command: String {
        switch self {
        case .paraspeakrs:
            return #"paraspeakrs agent diarize "$MACPARAKEET_AUDIO" -o "$MACPARAKEET_OUT_DIR""#
        }
    }

    public var applyCommand: String {
        switch self {
        case .paraspeakrs:
            return #"paraspeakrs agent apply "$MACPARAKEET_OUT_DIR""#
        }
    }
}

/// Where a transcription's external speaker-detection output lives, and how
/// the detector's speaker IDs appear in that transcription.
public enum ExternalSpeakerDetectionLocation {
    public static let folderName = "speaker-detection"

    /// Meetings keep it inside the meeting folder, so it goes with the
    /// meeting; other transcriptions get a folder of their own.
    public static func outputFolder(for transcription: Transcription) -> URL {
        if transcription.sourceType == .meeting, let path = transcription.meetingArtifactFolderPath {
            return outputFolder(inMeetingFolder: URL(fileURLWithPath: path, isDirectory: true))
        }
        return outputFolder(forTranscriptionID: transcription.id)
    }

    public static func outputFolder(inMeetingFolder folderURL: URL) -> URL {
        folderURL.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func outputFolder(forTranscriptionID id: UUID) -> URL {
        URL(fileURLWithPath: AppPaths.speakerDetectionDir, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// A meeting's external speakers cover microphone and system alike, so
    /// they are kept apart from the `microphone`/`system` source ids.
    public static let wholeMeetingIDPrefix = "external:"

    /// How the detector's speaker IDs are stored in a transcription: prefixed
    /// in meetings, unchanged in file transcriptions.
    public static func transcriptIDPrefix(for transcription: Transcription) -> String {
        transcription.sourceType == .meeting ? wholeMeetingIDPrefix : ""
    }
}
