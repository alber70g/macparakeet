import Foundation
import XCTest
@testable import MacParakeetCore

/// When the external transcriber is enabled it replaces built-in meeting STT
/// (ADR-035). A failure must leave the meeting in Error for Retry rather than
/// silently using another engine, and an explicitly chosen built-in engine
/// must bypass the command so the user always has a way out.
final class TranscriptionServiceExternalTranscriberTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var mockAudio: MockAudioProcessor!
    private var mockSTT: MockSTTClient!
    private var transcriptionRepo: TranscriptionRepository!
    private var runner: FakeExternalTranscriber!
    private var folder: URL!

    override func setUp() async throws {
        dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        runner = FakeExternalTranscriber()
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

    func testEnabledTranscriberReplacesBuiltInSTT() async throws {
        let service = makeService(enabled: true)

        let result = try await service.transcribeMeeting(recording: recording())

        let sttCalls = await mockSTT.transcribeCallCount
        XCTAssertEqual(sttCalls, 0, "Built-in STT must not run when the external command is enabled")
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.engine, "external")
        XCTAssertEqual(result.engineVariant, "paraspeakrs")
        XCTAssertEqual(result.rawTranscript, "Yeah. Ja, man. Hoe is hij?")
        XCTAssertEqual(result.speakers?.map(\.label), ["Albert", "Speaker 2"])
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertNotNil(result.transcriptSegments)
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.audio, folder.appendingPathComponent("meeting-playback.m4a"))
        XCTAssertEqual(call.output, folder.appendingPathComponent("external-transcript", isDirectory: true))
        XCTAssertEqual(call.meetingID, result.id)
    }

    func testFailureLeavesTheMeetingInErrorWithoutFallingBack() async throws {
        runner.error = ExternalTranscriberError.commandFailed("exit code 2: model missing")
        let service = makeService(enabled: true)

        do {
            _ = try await service.transcribeMeeting(recording: recording())
            XCTFail("Expected the external failure to surface")
        } catch {
            XCTAssertEqual(error as? ExternalTranscriberError, .commandFailed("exit code 2: model missing"))
        }

        let sttCalls = await mockSTT.transcribeCallCount
        XCTAssertEqual(sttCalls, 0)
        let saved = try XCTUnwrap(try transcriptionRepo.fetchAll(limit: 5).first)
        XCTAssertEqual(saved.status, .error)
        XCTAssertTrue(saved.errorMessage?.contains("model missing") == true)
    }

    func testDisabledTranscriberUsesBuiltInSTT() async throws {
        await mockSTT.configureSequence(results: [
            STTResult(text: "Hello", words: [TimestampedWord(word: "Hello", startMs: 0, endMs: 200, confidence: 0.9)]),
            STTResult(text: "Hi", words: [TimestampedWord(word: "Hi", startMs: 0, endMs: 200, confidence: 0.9)]),
        ])
        let service = makeService(enabled: false)

        let result = try await service.transcribeMeeting(recording: recording())

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertNotEqual(result.engine, "external")
    }

    func testRetranscribeUsesExternalUnlessABuiltInEngineIsChosen() async throws {
        let service = makeService(enabled: true)
        let original = try await service.transcribeMeeting(recording: recording())
        XCTAssertEqual(runner.calls.count, 1)

        _ = try await service.retranscribeMeeting(existing: original, recording: recording())
        XCTAssertEqual(runner.calls.count, 2, "Plain retranscribe/Retry runs the external command again")

        await mockSTT.configureSequence(results: [
            STTResult(text: "Hello", words: [TimestampedWord(word: "Hello", startMs: 0, endMs: 200, confidence: 0.9)]),
            STTResult(text: "Hi", words: [TimestampedWord(word: "Hi", startMs: 0, endMs: 200, confidence: 0.9)]),
        ])
        let builtIn = try await service.retranscribeMeeting(
            existing: original,
            recording: recording(),
            speechEngineOverride: SpeechEngineSelection(engine: .parakeet, language: nil)
        )
        XCTAssertEqual(runner.calls.count, 2, "An explicitly chosen engine bypasses the command")
        XCTAssertNotEqual(builtIn.engine, "external")
    }

    // MARK: - Helpers

    private func makeService(enabled: Bool) -> TranscriptionService {
        let configuration = ExternalTranscriberConfiguration(
            enabled: enabled,
            command: ExternalTranscriberPreset.paraspeakrs.command,
            applyCommand: ExternalTranscriberPreset.paraspeakrs.applyCommand
        )
        return TranscriptionService(
            audioProcessor: mockAudio,
            sttTranscriber: mockSTT,
            transcriptionRepo: transcriptionRepo,
            meetingAutomationHookRunner: nil,
            externalTranscriber: runner,
            externalTranscriberConfiguration: { configuration }
        )
    }

    private func recording() -> MeetingRecordingOutput {
        MeetingRecordingOutput(
            sessionID: UUID(),
            displayName: "Meeting",
            folderURL: folder,
            mixedAudioURL: folder.appendingPathComponent("meeting-playback.m4a"),
            microphoneAudioURL: folder.appendingPathComponent("microphone-raw.m4a"),
            systemAudioURL: folder.appendingPathComponent("system-raw.m4a"),
            durationSeconds: 10,
            sourceAlignment: MeetingSourceAlignment(
                meetingOriginHostTime: nil,
                microphone: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 48_000, sampleRate: 48_000),
                system: .init(firstHostTime: nil, lastHostTime: nil, startOffsetMs: 0, writtenFrameCount: 48_000, sampleRate: 48_000)
            )
        )
    }
}

final class FakeExternalTranscriber: ExternalTranscriberRunning, @unchecked Sendable {
    struct Call: Equatable {
        let audio: URL
        let output: URL
        let meetingID: UUID
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private(set) var applyCount = 0
    var error: Error?

    var calls: [Call] { lock.withLock { recordedCalls } }

    func transcribe(
        audioURL: URL,
        outputFolder: URL,
        meetingID: UUID,
        configuration: ExternalTranscriberConfiguration
    ) async throws -> ExternalTranscript {
        lock.withLock { recordedCalls.append(Call(audio: audioURL, output: outputFolder, meetingID: meetingID)) }
        if let error { throw error }
        return try ExternalTranscript.decode(Data(ExternalTranscriptTests.sampleJSON.utf8))
    }

    func apply(outputFolder: URL, meetingID: UUID, configuration: ExternalTranscriberConfiguration) async throws {
        lock.withLock { applyCount += 1 }
        if let error { throw error }
    }
}
