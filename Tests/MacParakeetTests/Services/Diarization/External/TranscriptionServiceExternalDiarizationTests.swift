import Foundation
import XCTest
@testable import MacParakeetCore

/// With an external detector selected, MacParakeet still recognizes the words
/// and the command only finds the speakers (ADR-035). These tests run the real
/// meeting and file pipelines through the same selectable service the app
/// builds, with a recording runner standing in for paraspeakrs.
final class TranscriptionServiceExternalDiarizationTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var mockAudio: MockAudioProcessor!
    private var mockSTT: MockSTTClient!
    private var transcriptionRepo: TranscriptionRepository!
    private var runner: RecordingDiarizerRunner!
    private var builtIn: MockDiarizationService!
    private var folder: URL!

    override func setUp() async throws {
        dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        runner = RecordingDiarizerRunner()
        builtIn = MockDiarizationService()
        Telemetry.configure(NoOpTelemetryService())
        folder = URL(fileURLWithPath: AppPaths.tempDir).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["meeting-playback.m4a", "microphone-raw.m4a", "system-raw.m4a"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("a".utf8))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMeetingSpeakersComeFromTheCommandAndKeepItsNames() async throws {
        await mockSTT.configureSequence(results: meetingSTTResults())
        let service = makeService(externalActive: true)

        let result = try await service.transcribeMeeting(recording: recording())

        let builtInCalled = await builtIn.diarizeCalled
        XCTAssertFalse(builtInCalled, "The built-in diarizer must not run when the command is selected")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.output, folder.appendingPathComponent("speaker-detection", isDirectory: true))
        XCTAssertEqual(call.transcriptionID, result.id)
        // The voice library's name survives the meeting's "Others N" numbering.
        let system = result.speakers?.filter { $0.id.hasPrefix("system:") }
        XCTAssertEqual(
            system,
            [
                SpeakerInfo(id: "system:L_SPEAKER_00", label: "Albert"),
                SpeakerInfo(id: "system:R_SPEAKER_00", label: "Others 2"),
            ])
        XCTAssertEqual(
            result.wordTimestamps?.map(\.speakerId),
            ["microphone", "system:L_SPEAKER_00", "system:R_SPEAKER_00"]
        )
    }

    func testMeetingKeepsItsTranscriptWhenTheCommandFailsAndRecordsWhy() async throws {
        await mockSTT.configureSequence(results: meetingSTTResults())
        runner.error = ExternalDiarizerError.commandFailed("exit code 2: error: model missing")
        let service = makeService(externalActive: true)

        let result = try await service.transcribeMeeting(recording: recording())

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.wordTimestamps?.map(\.word), ["Hallo", "Ja", "Hoe"])
        XCTAssertFalse(result.speakers?.contains { $0.id.hasPrefix("system:L") } ?? false)
        let builtInCalled = await builtIn.diarizeCalled
        XCTAssertFalse(builtInCalled, "A failed command must not silently fall back to the built-in diarizer")
        let message = ExternalDiarizationService.lastError(
            inOutputFolder: folder.appendingPathComponent("speaker-detection")
        )
        XCTAssertTrue(message?.contains("model missing") == true)
    }

    func testBuiltInSelectionRemovesSamplesOfAnEarlierExternalRun() async throws {
        await mockSTT.configureSequence(results: meetingSTTResults())
        let stale = folder.appendingPathComponent("speaker-detection", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: stale.appendingPathComponent("SPEAKER_00__Bob.wav"))
        let service = makeService(externalActive: false)

        _ = try await service.transcribeMeeting(recording: recording())

        let builtInCalled = await builtIn.diarizeCalled
        XCTAssertTrue(builtInCalled)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testFileTranscriptionKeepsSamplesInItsOwnFolder() async throws {
        await mockSTT.configure(
            result: STTResult(
                text: "Ja Hoe",
                words: [
                    TimestampedWord(word: "Ja", startMs: 2000, endMs: 2400, confidence: 0.9),
                    TimestampedWord(word: "Hoe", startMs: 8500, endMs: 8800, confidence: 0.9),
                ]
            ))
        let service = makeService(externalActive: true)

        let result = try await service.transcribe(fileURL: folder.appendingPathComponent("meeting-playback.m4a"))

        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.output, ExternalSpeakerDetectionLocation.outputFolder(forTranscriptionID: result.id))
        XCTAssertEqual(result.wordTimestamps?.map(\.speakerId), ["L_SPEAKER_00", "R_SPEAKER_00"])
        XCTAssertEqual(result.speakers?.first, SpeakerInfo(id: "L_SPEAKER_00", label: "Albert"))
        try? FileManager.default.removeItem(at: call.output)
    }

    func testDeletingAFileTranscriptionRemovesItsSpeakerSamples() throws {
        let transcription = Transcription(fileName: "a.m4a", status: .completed, sourceType: .file)
        try transcriptionRepo.save(transcription)
        let samples = ExternalSpeakerDetectionLocation.outputFolder(forTranscriptionID: transcription.id)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: samples.appendingPathComponent("SPEAKER_00__Bob.wav"))

        XCTAssertTrue(try TranscriptionDeletionCoordinator.delete(transcription, repository: transcriptionRepo))

        XCTAssertFalse(FileManager.default.fileExists(atPath: samples.path))
    }

    /// The external detector needs no speaker models; with it selected,
    /// readiness checks must not trigger a built-in model download.
    func testModelPreparationFollowsTheSelection() async throws {
        let external = makeSelectable(externalActive: true)
        try await external.prepareModels(onProgress: nil)
        let prepared = await builtIn.prepareModelsCalled
        XCTAssertFalse(prepared)
        let ready = await external.isReady()
        XCTAssertTrue(ready)

        try await makeSelectable(externalActive: false).prepareModels(onProgress: nil)
        let preparedBuiltIn = await builtIn.prepareModelsCalled
        XCTAssertTrue(preparedBuiltIn)
    }

    // MARK: - Helpers

    private func makeSelectable(externalActive: Bool) -> SelectableDiarizationService {
        let configuration = ExternalDiarizerConfiguration(
            enabled: externalActive,
            command: ExternalDiarizerPreset.paraspeakrs.command,
            applyCommand: ExternalDiarizerPreset.paraspeakrs.applyCommand
        )
        return SelectableDiarizationService(
            builtIn: builtIn,
            external: ExternalDiarizationService(runner: runner) { configuration },
            configuration: { configuration }
        )
    }

    private func makeService(externalActive: Bool) -> TranscriptionService {
        TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            shouldDiarize: { true },
            shouldDiarizeMeetings: { true },
            diarizationService: makeSelectable(externalActive: externalActive)
        )
    }

    /// Microphone first, then system: words at times the sample turns cover.
    private func meetingSTTResults() -> [STTResult] {
        [
            STTResult(
                text: "Hallo",
                words: [TimestampedWord(word: "Hallo", startMs: 0, endMs: 400, confidence: 0.9)]
            ),
            STTResult(
                text: "Ja Hoe",
                words: [
                    TimestampedWord(word: "Ja", startMs: 2000, endMs: 2400, confidence: 0.9),
                    TimestampedWord(word: "Hoe", startMs: 8500, endMs: 8800, confidence: 0.9),
                ]
            ),
        ]
    }

    private func recording() -> MeetingRecordingOutput {
        MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting",
            folderURL: folder,
            mixedAudioURL: folder.appendingPathComponent("meeting-playback.m4a"),
            microphoneAudioURL: folder.appendingPathComponent("microphone-raw.m4a"),
            systemAudioURL: folder.appendingPathComponent("system-raw.m4a"),
            durationSeconds: 12,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(
                    firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 576_000,
                    sampleRate: 48_000),
                system: .init(
                    firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 576_000,
                    sampleRate: 48_000)
            )
        )
    }
}
