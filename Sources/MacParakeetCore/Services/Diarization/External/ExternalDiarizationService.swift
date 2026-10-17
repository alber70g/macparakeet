import Foundation

/// Speaker detection by an external command such as paraspeakrs (ADR-035).
/// Needs no local models. A run without a transcription context writes to a
/// temporary folder that is removed afterwards, so it leaves no samples.
public struct ExternalDiarizationService: DiarizationServiceProtocol {
    /// Written next to the samples when a run fails, so the transcript view
    /// can say why a transcript has no speakers.
    public static let errorFileName = "macparakeet-error.txt"

    private let runner: any ExternalDiarizerRunning
    private let configuration: @Sendable () -> ExternalDiarizerConfiguration

    public init(
        runner: any ExternalDiarizerRunning = ExternalDiarizerRunner(),
        configuration: @escaping @Sendable () -> ExternalDiarizerConfiguration
    ) {
        self.runner = runner
        self.configuration = configuration
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        try await diarize(audioURL: audioURL, speakerConstraint: speakerConstraint, context: nil)
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?,
        context: DiarizationRunContext?
    ) async throws -> MacParakeetDiarizationResult {
        let outputFolder =
            context?.outputFolder
            ?? URL(fileURLWithPath: AppPaths.tempDir, isDirectory: true)
            .appendingPathComponent("speaker-detection-\(UUID().uuidString)", isDirectory: true)
        defer {
            if context == nil { try? FileManager.default.removeItem(at: outputFolder) }
        }
        do {
            return try await runner.diarize(
                audioURL: audioURL,
                outputFolder: outputFolder,
                transcriptionID: context?.transcriptionID,
                configuration: configuration()
            ).result()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if context != nil {
                try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
                try? Data(error.localizedDescription.utf8)
                    .write(to: outputFolder.appendingPathComponent(Self.errorFileName), options: .atomic)
            }
            throw error
        }
    }

    /// paraspeakrs diarizes each side of the stereo meeting playback, so people
    /// in the room on the microphone are found too.
    public func diarizesWholeMeeting() async -> Bool { true }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {}

    public func isReady() async -> Bool { true }

    public func hasCachedModels() async -> Bool { true }

    /// Why the last run for this output folder failed, or nil.
    public static func lastError(inOutputFolder folder: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(errorFileName).path)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Runs the built-in diarizer or the external command, whichever Settings
/// selects at the time of the call, so a change applies to the next run
/// without a restart. Model preparation follows the selection: with the
/// external command active, no built-in speaker models are downloaded.
public struct SelectableDiarizationService: DiarizationServiceProtocol {
    let builtIn: any DiarizationServiceProtocol
    private let external: any DiarizationServiceProtocol
    private let configuration: @Sendable () -> ExternalDiarizerConfiguration

    public init(
        builtIn: any DiarizationServiceProtocol,
        external: any DiarizationServiceProtocol,
        configuration: @escaping @Sendable () -> ExternalDiarizerConfiguration
    ) {
        self.builtIn = builtIn
        self.external = external
        self.configuration = configuration
    }

    private var active: any DiarizationServiceProtocol {
        configuration().isActive ? external : builtIn
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        try await active.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?,
        context: DiarizationRunContext?
    ) async throws -> MacParakeetDiarizationResult {
        guard configuration().isActive else {
            // Samples from an earlier external run would no longer match the
            // speakers this run produces.
            if let context { try? FileManager.default.removeItem(at: context.outputFolder) }
            return try await builtIn.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint, context: context)
        }
        return try await external.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint, context: context)
    }

    public func diarizesWholeMeeting() async -> Bool { await active.diarizesWholeMeeting() }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await active.prepareModels(onProgress: onProgress)
    }

    public func isReady() async -> Bool { await active.isReady() }

    public func hasCachedModels() async -> Bool { await active.hasCachedModels() }

    public func explicitSpeakerConstraint() async -> SpeakerDiarizationConstraint? {
        await active.explicitSpeakerConstraint()
    }
}
