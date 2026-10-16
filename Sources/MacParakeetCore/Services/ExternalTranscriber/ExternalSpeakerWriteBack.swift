import Foundation

public protocol ExternalSpeakerWriteBacking: Sendable {
    /// Makes the tool's sample files match the names MacParakeet shows, then
    /// runs the apply command if any file moved. Returns whether it applied.
    @discardableResult
    func sync(
        meetingID: UUID,
        meetingFolder: URL,
        attribution: EffectiveSpeakerAttribution
    ) async throws -> Bool

    /// Confirms a voice-library suggestion so the tool learns the voice.
    func confirmSuggestion(
        meetingID: UUID,
        meetingFolder: URL,
        transcriptSpeakerID: String
    ) async throws
}

public enum ExternalSpeakerWriteBackError: Error, LocalizedError, Equatable {
    case noSuggestion

    public var errorDescription: String? {
        switch self {
        case .noSuggestion:
            return "This speaker has no voice-library suggestion to confirm."
        }
    }
}

/// Writes speaker names back to the external transcriber (ADR-035).
/// Runs one write-back at a time so moves and apply runs never interleave.
public actor ExternalSpeakerWriteBack: ExternalSpeakerWriteBacking {
    private let runner: ExternalTranscriberRunning
    private let configuration: @Sendable () -> ExternalTranscriberConfiguration

    public init(
        runner: ExternalTranscriberRunning = ExternalTranscriberRunner(),
        configuration: @escaping @Sendable () -> ExternalTranscriberConfiguration = { .current() }
    ) {
        self.runner = runner
        self.configuration = configuration
    }

    @discardableResult
    public func sync(
        meetingID: UUID,
        meetingFolder: URL,
        attribution: EffectiveSpeakerAttribution
    ) async throws -> Bool {
        let configuration = configuration()
        guard configuration.writesBackNames,
            let naming = ExternalSpeakerNaming.load(meetingFolder: meetingFolder)
        else { return false }
        guard try naming.applyFileMoves(naming.plan(attribution: attribution)) else { return false }
        try await runner.apply(outputFolder: naming.outputFolder, meetingID: meetingID, configuration: configuration)
        return true
    }

    public func confirmSuggestion(
        meetingID: UUID,
        meetingFolder: URL,
        transcriptSpeakerID: String
    ) async throws {
        let configuration = configuration()
        guard configuration.writesBackNames else { throw ExternalTranscriberError.notConfigured }
        guard let naming = ExternalSpeakerNaming.load(meetingFolder: meetingFolder),
            let speaker = naming.speaker(forTranscriptID: transcriptSpeakerID),
            speaker.hasUnconfirmedSuggestion,
            let label = speaker.suggestedLabel
        else { throw ExternalSpeakerWriteBackError.noSuggestion }
        try naming.applyFileMoves([speaker.externalID: .named(label)])
        try await runner.apply(outputFolder: naming.outputFolder, meetingID: meetingID, configuration: configuration)
    }
}
