import Foundation
import XCTest
@testable import MacParakeetCore

/// Write-back turns MacParakeet's effective speaker roster into paraspeakrs
/// sample file names. A wrong name teaches the voice library the wrong voice,
/// and a wrong drop removes a speaker in the tool, so each rule of ADR-035 is
/// pinned here against real corrections on a meeting, whose detector speakers
/// are stored as `external:<detector id>`.
final class ExternalSpeakerNamingTests: XCTestCase {
    private var meetingFolder: URL!
    private var outputFolder: URL!
    /// Built once: `materializeSegments` assigns fresh segment IDs per call,
    /// and correction targets must anchor to the same transcript they replay on.
    private var cachedMeeting: Transcription?

    override func setUpWithError() throws {
        meetingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalSpeakerNamingTests-\(UUID().uuidString)")
        outputFolder = ExternalSpeakerDetectionLocation.outputFolder(inMeetingFolder: meetingFolder)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try Data(ExternalDiarizationTests.sampleJSON.utf8)
            .write(to: outputFolder.appendingPathComponent(ExternalDiarization.fileName))
        for name in ["L_SPEAKER_00__Albert_0.77.wav", "R_SPEAKER_00__NAME-ME.wav"] {
            try Data("wav".utf8).write(to: outputFolder.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: meetingFolder)
    }

    func testLoadFindsSamplesAndUnconfirmedSuggestion() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))

        let albert = try XCTUnwrap(naming.speaker(forTranscriptID: "external:L_SPEAKER_00"))
        XCTAssertEqual(albert.sampleURL?.lastPathComponent, "L_SPEAKER_00__Albert_0.77.wav")
        XCTAssertTrue(albert.hasUnconfirmedSuggestion)
        let other = try XCTUnwrap(naming.speaker(forTranscriptID: "external:R_SPEAKER_00"))
        XCTAssertFalse(other.hasUnconfirmedSuggestion)
        XCTAssertNil(naming.speaker(forTranscriptID: "microphone"))
    }

    /// File transcriptions keep the detector's IDs unprefixed.
    func testUnprefixedTranscriptIDMatchesForFileTranscriptions() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))

        XCTAssertEqual(naming.speaker(forTranscriptID: "R_SPEAKER_00")?.externalID, "R_SPEAKER_00")
    }

    func testMeetingFolderLocationAndPrefixFollowTheTranscription() throws {
        let meeting = try meeting()
        XCTAssertEqual(ExternalSpeakerDetectionLocation.outputFolder(for: meeting), outputFolder)
        XCTAssertEqual(ExternalSpeakerDetectionLocation.transcriptIDPrefix(for: meeting), "external:")

        var file = meeting
        file.sourceType = .file
        XCTAssertEqual(
            ExternalSpeakerDetectionLocation.outputFolder(for: file).lastPathComponent,
            meeting.id.uuidString
        )
        XCTAssertEqual(ExternalSpeakerDetectionLocation.transcriptIDPrefix(for: file), "")
    }

    func testUntouchedSuggestionIsKeptSoTheLibraryIsNotTaught() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))

        let targets = naming.plan(attribution: try resolve([]))

        XCTAssertEqual(targets["L_SPEAKER_00"], .keep)
        XCTAssertEqual(targets["R_SPEAKER_00"], .unnamed)
        XCTAssertFalse(try naming.applyFileMoves(targets))
    }

    func testRenameNamesTheSample() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))

        let targets = naming.plan(
            attribution: try resolve([
                .rename(speakerID: "external:R_SPEAKER_00", label: "Randy")
            ]))

        XCTAssertEqual(targets["R_SPEAKER_00"], .named("Randy"))
        XCTAssertTrue(try naming.applyFileMoves(targets))
        XCTAssertTrue(fileExists("R_SPEAKER_00__Randy.wav"))
        XCTAssertFalse(fileExists("R_SPEAKER_00__NAME-ME.wav"))
    }

    func testRenamingASuggestedSpeakerReplacesTheGuess() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))

        let targets = naming.plan(
            attribution: try resolve([
                .rename(speakerID: "external:L_SPEAKER_00", label: "Steven")
            ]))

        XCTAssertEqual(targets["L_SPEAKER_00"], .named("Steven"))
    }

    func testMergeGivesBothSamplesTheTargetName() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))

        let targets = naming.plan(
            attribution: try resolve([
                .merge(sourceSpeakerID: "external:R_SPEAKER_00", targetSpeakerID: "external:L_SPEAKER_00")
            ]))

        // The same name on two samples is how paraspeakrs merges speakers.
        XCTAssertEqual(targets["R_SPEAKER_00"], .named("Albert"))
    }

    func testOmittingEveryLineDropsTheSpeakerAndUndoRestoresIt() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))
        let automatic = try resolve([])
        let omissions = automatic.editableSegments
            .filter { $0.assignment == .speaker(id: "external:R_SPEAKER_00") }
            .map {
                TranscriptTextChange.omit(
                    target: SpeakerCorrectionTarget(
                        anchorTranscriptSegmentIDs: $0.anchorTranscriptSegmentIDs,
                        wordRange: $0.wordRange
                    ))
            }
        XCTAssertFalse(omissions.isEmpty)

        // The exact pair the Drop action commits: omit the lines, then remove
        // the speaker. `resolve` fails if either command does not replay.
        let dropped = naming.plan(
            attribution: try resolve([
                .reviseText(changes: omissions),
                .remove(speakerID: "external:R_SPEAKER_00", reassignTo: .unassigned),
            ])
        )
        XCTAssertEqual(dropped["R_SPEAKER_00"], .dropped)
        XCTAssertTrue(try naming.applyFileMoves(dropped))
        // Moved aside, not deleted: Undo must be able to bring the speaker back.
        XCTAssertTrue(fileExists("dropped/R_SPEAKER_00__NAME-ME.wav"))
        XCTAssertFalse(fileExists("R_SPEAKER_00__NAME-ME.wav"))

        let reloaded = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))
        let restored = reloaded.plan(attribution: automatic)
        XCTAssertEqual(restored["R_SPEAKER_00"], .unnamed)
        XCTAssertTrue(try reloaded.applyFileMoves(restored))
        XCTAssertTrue(fileExists("R_SPEAKER_00__NAME-ME.wav"))
    }

    func testConfirmedSuggestionStaysNamedAfterwards() throws {
        try FileManager.default.moveItem(
            at: outputFolder.appendingPathComponent("L_SPEAKER_00__Albert_0.77.wav"),
            to: outputFolder.appendingPathComponent("L_SPEAKER_00__Albert.wav")
        )
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: outputFolder))

        XCTAssertFalse(try XCTUnwrap(naming.speaker(forTranscriptID: "external:L_SPEAKER_00")).hasUnconfirmedSuggestion)
        // A later sync must not turn the confirmation back into a guess.
        XCTAssertEqual(naming.plan(attribution: try resolve([]))["L_SPEAKER_00"], .named("Albert"))
    }

    func testWriteBackMovesFilesThenRunsApplyOnce() async throws {
        let runner = RecordingDiarizerRunner()
        let writeBack = ExternalSpeakerWriteBack(runner: runner) {
            ExternalDiarizerConfiguration(enabled: true, command: "true", applyCommand: "true")
        }
        let meetingID = try meeting().id

        let applied = try await writeBack.sync(
            transcriptionID: meetingID,
            outputFolder: outputFolder,
            attribution: try resolve([.rename(speakerID: "external:R_SPEAKER_00", label: "Randy")])
        )
        XCTAssertTrue(applied)
        XCTAssertEqual(runner.applyCount, 1)

        // Nothing changed since: no second apply run.
        let again = try await writeBack.sync(
            transcriptionID: meetingID,
            outputFolder: outputFolder,
            attribution: try resolve([.rename(speakerID: "external:R_SPEAKER_00", label: "Randy")])
        )
        XCTAssertFalse(again)
        XCTAssertEqual(runner.applyCount, 1)
    }

    func testConfirmSuggestionNamesTheSampleAndApplies() async throws {
        let runner = RecordingDiarizerRunner()
        let writeBack = ExternalSpeakerWriteBack(runner: runner) {
            ExternalDiarizerConfiguration(enabled: true, command: "true", applyCommand: "true")
        }

        try await writeBack.confirmSuggestion(
            transcriptionID: UUID(),
            outputFolder: outputFolder,
            transcriptSpeakerID: "external:L_SPEAKER_00"
        )

        XCTAssertTrue(fileExists("L_SPEAKER_00__Albert.wav"))
        XCTAssertEqual(runner.applyCount, 1)
    }

    func testSafeNameMatchesParaspeakrs() {
        XCTAssertEqual(ExternalSpeakerNaming.safeName(" A/B "), "A-B")
        XCTAssertEqual(ExternalSpeakerNaming.safeName("  "), "NAME-ME")
    }

    // MARK: - Helpers

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent(relativePath).path)
    }

    /// A meeting as the pipeline stores one after external detection: the
    /// detector speakers carry the `external:` prefix, an uncovered word keeps
    /// its source id ("Me"), and a name the detector supplied is kept.
    private func meeting() throws -> Transcription {
        if let cachedMeeting { return cachedMeeting }
        let words = [
            WordTimestamp(word: "Hallo.", startMs: 0, endMs: 400, confidence: 1, speakerId: "microphone"),
            WordTimestamp(word: "Ja,", startMs: 1752, endMs: 2152, confidence: 1, speakerId: "external:L_SPEAKER_00"),
            WordTimestamp(word: "man.", startMs: 3592, endMs: 4232, confidence: 1, speakerId: "external:L_SPEAKER_00"),
            WordTimestamp(word: "Hoe", startMs: 8400, endMs: 8800, confidence: 1, speakerId: "external:R_SPEAKER_00"),
            WordTimestamp(word: "is", startMs: 8800, endMs: 9000, confidence: 1, speakerId: "external:R_SPEAKER_00"),
            WordTimestamp(word: "hij?", startMs: 9000, endMs: 9300, confidence: 1, speakerId: "external:R_SPEAKER_00"),
        ]
        let speakers = [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "external:L_SPEAKER_00", label: "Albert"),
            SpeakerInfo(id: "external:R_SPEAKER_00", label: "Speaker 2"),
        ]
        let transcription = Transcription(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            fileName: "Meeting",
            meetingArtifactFolderPath: meetingFolder.path,
            rawTranscript: words.map(\.word).joined(separator: " "),
            wordTimestamps: words,
            speakers: speakers,
            transcriptSegments: TranscriptSegmenter.materializeSegments(words: words, speakers: speakers),
            status: .completed,
            sourceType: .meeting
        )
        cachedMeeting = transcription
        return transcription
    }

    private func resolve(_ commands: [SpeakerCorrectionCommand]) throws -> EffectiveSpeakerAttribution {
        let transcription = try meeting()
        let fingerprint = SpeakerAttributionResolver.fingerprint(for: transcription)
        var corrections: [SpeakerCorrection] = []
        for (index, command) in commands.enumerated() {
            corrections.append(
                SpeakerCorrection(
                    transcriptionId: transcription.id,
                    parentId: corrections.last?.id,
                    sequence: index + 1,
                    transcriptFingerprint: fingerprint,
                    payload: command,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                ))
        }
        let attribution = SpeakerAttributionResolver.resolve(
            transcription: transcription,
            corrections: corrections,
            state: corrections.last.map {
                SpeakerCorrectionState(
                    transcriptionId: transcription.id,
                    transcriptFingerprint: fingerprint.rawValue,
                    headId: $0.id,
                    revision: corrections.count
                )
            }
        )
        XCTAssertEqual(attribution.unresolvedCorrections, [], "Corrections must replay for the plan to be meaningful")
        return attribution
    }
}

/// Records apply runs; diarize returns the sample diarization.
final class RecordingDiarizerRunner: ExternalDiarizerRunning, @unchecked Sendable {
    struct Call: Equatable {
        let audio: URL
        let output: URL
        let transcriptionID: UUID?
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var recordedApplyCount = 0
    var error: Error?

    var calls: [Call] { lock.withLock { recordedCalls } }
    var applyCount: Int { lock.withLock { recordedApplyCount } }

    func diarize(
        audioURL: URL,
        outputFolder: URL,
        transcriptionID: UUID?,
        configuration: ExternalDiarizerConfiguration
    ) async throws -> ExternalDiarization {
        lock.withLock {
            recordedCalls.append(Call(audio: audioURL, output: outputFolder, transcriptionID: transcriptionID))
        }
        if let error { throw error }
        return try ExternalDiarization.decode(Data(ExternalDiarizationTests.sampleJSON.utf8))
    }

    func apply(outputFolder: URL, transcriptionID: UUID, configuration: ExternalDiarizerConfiguration) async throws {
        lock.withLock { recordedApplyCount += 1 }
        if let error { throw error }
    }
}
