import Foundation
import XCTest
@testable import MacParakeetCore

/// Write-back turns MacParakeet's effective speaker roster into paraspeakrs
/// sample file names. A wrong name teaches the voice library the wrong voice,
/// and a wrong drop deletes a speaker's lines in the tool, so each rule of
/// ADR-035 is pinned here against real corrections.
final class ExternalSpeakerNamingTests: XCTestCase {
    private var meetingFolder: URL!
    private var outputFolder: URL!
    /// Built once: `materializeSegments` assigns fresh segment IDs per call,
    /// and correction targets must anchor to the same transcript they replay on.
    private var cachedMeeting: Transcription?

    override func setUpWithError() throws {
        meetingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalSpeakerNamingTests-\(UUID().uuidString)")
        outputFolder = ExternalTranscriberConfiguration.outputFolder(inMeetingFolder: meetingFolder)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try Data(ExternalTranscriptTests.sampleJSON.utf8)
            .write(to: outputFolder.appendingPathComponent(ExternalTranscript.fileName))
        for name in ["L_SPEAKER_00__Albert_0.77.wav", "R_SPEAKER_00__NAME-ME.wav"] {
            try Data("wav".utf8).write(to: outputFolder.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: meetingFolder)
    }

    func testLoadFindsSamplesAndUnconfirmedSuggestion() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))

        let albert = try XCTUnwrap(naming.speaker(forTranscriptID: "external:L_SPEAKER_00"))
        XCTAssertEqual(albert.sampleURL?.lastPathComponent, "L_SPEAKER_00__Albert_0.77.wav")
        XCTAssertTrue(albert.hasUnconfirmedSuggestion)
        let other = try XCTUnwrap(naming.speaker(forTranscriptID: "external:R_SPEAKER_00"))
        XCTAssertFalse(other.hasUnconfirmedSuggestion)
        XCTAssertNil(naming.speaker(forTranscriptID: "microphone"))
    }

    func testUntouchedSuggestionIsKeptSoTheLibraryIsNotTaught() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))

        let targets = naming.plan(attribution: try resolve([]))

        XCTAssertEqual(targets["L_SPEAKER_00"], .keep)
        XCTAssertEqual(targets["R_SPEAKER_00"], .unnamed)
        XCTAssertFalse(try naming.applyFileMoves(targets))
    }

    func testRenameNamesTheSample() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))

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
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))

        let targets = naming.plan(
            attribution: try resolve([
                .rename(speakerID: "external:L_SPEAKER_00", label: "Steven")
            ]))

        XCTAssertEqual(targets["L_SPEAKER_00"], .named("Steven"))
    }

    func testMergeGivesBothSamplesTheTargetName() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))

        let targets = naming.plan(
            attribution: try resolve([
                .merge(sourceSpeakerID: "external:R_SPEAKER_00", targetSpeakerID: "external:L_SPEAKER_00")
            ]))

        // The same name on two samples is how paraspeakrs merges speakers.
        XCTAssertEqual(targets["R_SPEAKER_00"], .named("Albert"))
    }

    func testOmittingEveryLineDropsTheSpeakerAndUndoRestoresIt() throws {
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))
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

        let reloaded = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))
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
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(meetingFolder: meetingFolder))

        XCTAssertFalse(try XCTUnwrap(naming.speaker(forTranscriptID: "external:L_SPEAKER_00")).hasUnconfirmedSuggestion)
        // A later sync must not turn the confirmation back into a guess.
        XCTAssertEqual(naming.plan(attribution: try resolve([]))["L_SPEAKER_00"], .named("Albert"))
    }

    func testSafeNameMatchesParaspeakrs() {
        XCTAssertEqual(ExternalSpeakerNaming.safeName(" A/B "), "A-B")
        XCTAssertEqual(ExternalSpeakerNaming.safeName("  "), "NAME-ME")
    }

    // MARK: - Helpers

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: outputFolder.appendingPathComponent(relativePath).path)
    }

    private func meeting() throws -> Transcription {
        if let cachedMeeting { return cachedMeeting }
        let imported = try ExternalTranscript.decode(Data(ExternalTranscriptTests.sampleJSON.utf8)).imported()
        let transcription = Transcription(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            fileName: "Meeting",
            meetingArtifactFolderPath: meetingFolder.path,
            rawTranscript: imported.rawTranscript,
            wordTimestamps: imported.words,
            speakers: imported.speakers,
            diarizationSegments: imported.diarizationSegments,
            transcriptSegments: TranscriptSegmenter.materializeSegments(
                words: imported.words,
                speakers: imported.speakers
            ),
            status: .completed,
            sourceType: .meeting,
            engine: ExternalTranscriberConfiguration.engineName
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
