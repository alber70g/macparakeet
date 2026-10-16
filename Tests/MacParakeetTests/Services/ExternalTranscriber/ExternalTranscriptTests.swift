import Foundation
import XCTest
@testable import MacParakeetCore

/// The import of an external transcriber's transcript.json is the only path
/// its words, timings and speakers take into a meeting, so these tests pin
/// the mapping the meeting view, exports and write-back rely on.
final class ExternalTranscriptTests: XCTestCase {
    func testImportKeepsWordTimingsAndPrefixesSpeakerIDs() throws {
        let imported = try ExternalTranscript.decode(Data(Self.sampleJSON.utf8)).imported()

        XCTAssertEqual(imported.words.map(\.word), ["Yeah.", "Ja,", "man.", "Hoe", "is", "hij?"])
        XCTAssertEqual(imported.words[1].startMs, 1752)
        XCTAssertEqual(imported.words[1].endMs, 2152)
        // Prefixed so external IDs never collide with the built-in
        // `microphone`/`system` roster semantics.
        XCTAssertEqual(imported.words[1].speakerId, "external:L_SPEAKER_00")
        XCTAssertEqual(imported.rawTranscript, "Yeah. Ja, man. Hoe is hij?")
    }

    func testUnattributedSegmentStaysUnassigned() throws {
        let imported = try ExternalTranscript.decode(Data(Self.sampleJSON.utf8)).imported()

        // A null speaker must not be guessed into a person.
        XCTAssertNil(imported.words[0].speakerId)
    }

    func testRosterShowsSuggestedNamesAndNumbersUnnamedSpeakers() throws {
        let imported = try ExternalTranscript.decode(Data(Self.sampleJSON.utf8)).imported()

        XCTAssertEqual(imported.speakers, [
            SpeakerInfo(id: "external:L_SPEAKER_00", label: "Albert"),
            SpeakerInfo(id: "external:R_SPEAKER_00", label: "Speaker 2"),
        ])
        // "Speaker N" reads as unnamed everywhere the app offers naming.
        XCTAssertTrue(imported.speakers[1].carriesAutomaticLabel)
    }

    func testExcludedSpeakerAndSpeakersWithoutWordsAreLeftOut() throws {
        let imported = try ExternalTranscript.decode(Data(Self.sampleJSON.utf8)).imported()

        XCTAssertFalse(imported.speakers.contains { $0.id == "external:R_SPEAKER_01" })
        XCTAssertFalse(imported.words.contains { $0.speakerId == "external:R_SPEAKER_01" })
    }

    func testSegmentWithoutWordsBecomesOneTokenAtSegmentTiming() throws {
        let json = """
        {"version": 1, "speakers": [{"id": "A"}],
         "segments": [{"speaker": "A", "start": 2.0, "end": 3.5, "text": "Hello there", "words": []}]}
        """
        let imported = try ExternalTranscript.decode(Data(json.utf8)).imported()

        // No invented per-word timings: the whole line keeps its own envelope.
        XCTAssertEqual(imported.words, [
            WordTimestamp(word: "Hello there", startMs: 2000, endMs: 3500, confidence: 1.0, speakerId: "external:A"),
        ])
    }

    func testDiarizationSegmentsFollowSpeakerTurns() throws {
        let imported = try ExternalTranscript.decode(Data(Self.sampleJSON.utf8)).imported()

        XCTAssertEqual(imported.diarizationSegments.map(\.speakerId), [
            "external:L_SPEAKER_00", "external:R_SPEAKER_00",
        ])
    }

    func testUnsupportedVersionIsRejected() {
        let json = #"{"version": 2, "speakers": [], "segments": []}"#

        XCTAssertThrowsError(try ExternalTranscript.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ExternalTranscript.ParseError, .unsupportedVersion(2))
        }
    }

    func testMissingFileNamesThePathItExpected() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try ExternalTranscript.load(fromFolder: folder)) { error in
            guard case .missing(let path) = error as? ExternalTranscript.ParseError else {
                return XCTFail("Expected missing, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("transcript.json"))
        }
    }

    static let sampleJSON = """
    {
      "version": 1,
      "job_id": "job",
      "language": null,
      "speakers": [
        {"id": "L_SPEAKER_00", "label": "Albert", "label_source": "suggestion",
         "suggested_label": "Albert", "suggestion_score": 0.77,
         "sample_file": "L_SPEAKER_00__Albert_0.77.wav", "excluded": false},
        {"id": "R_SPEAKER_00", "label": null, "label_source": null,
         "suggested_label": null, "suggestion_score": null,
         "sample_file": "R_SPEAKER_00__NAME-ME.wav", "excluded": false},
        {"id": "R_SPEAKER_01", "label": "Gone", "label_source": "named",
         "sample_file": null, "excluded": true}
      ],
      "segments": [
        {"speaker": null, "start": 1.2, "end": 1.6, "text": "Yeah.",
         "words": [{"word": "Yeah.", "start": 1.2, "end": 1.6}]},
        {"speaker": "L_SPEAKER_00", "start": 1.752, "end": 4.232, "text": "Ja, man.",
         "words": [{"word": "Ja,", "start": 1.752, "end": 2.152}, {"word": "man.", "start": 3.592, "end": 4.232}]},
        {"speaker": "R_SPEAKER_00", "start": 8.4, "end": 9.3, "text": "Hoe is hij?",
         "words": [{"word": "Hoe", "start": 8.4, "end": 8.8}, {"word": "is", "start": 8.8, "end": 9.0},
                   {"word": "hij?", "start": 9.0, "end": 9.3}]}
      ]
    }
    """
}
