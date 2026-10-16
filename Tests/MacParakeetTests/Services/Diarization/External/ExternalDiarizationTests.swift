import Foundation
import XCTest
@testable import MacParakeetCore

/// `diarization.json` is the only path an external detector's speakers take
/// into a transcript, so these tests pin the mapping that word attribution,
/// the speaker roster and naming rely on.
final class ExternalDiarizationTests: XCTestCase {
    func testTurnsBecomeMillisecondSegmentsInTimeOrder() throws {
        let result = try ExternalDiarization.decode(Data(Self.sampleJSON.utf8)).result()

        XCTAssertEqual(result.segments.map(\.speakerId), ["L_SPEAKER_00", "R_SPEAKER_00", "L_SPEAKER_00"])
        XCTAssertEqual(result.segments.map(\.startMs), [1752, 8400, 10_000])
        XCTAssertEqual(result.segments.map(\.endMs), [4232, 9300, 11_500])
        XCTAssertEqual(result.speechMsBySpeaker["L_SPEAKER_00"], (4232 - 1752) + 1500)
    }

    func testNamedSpeakerKeepsItsNameAndUnnamedOneIsNumbered() throws {
        let result = try ExternalDiarization.decode(Data(Self.sampleJSON.utf8)).result()

        XCTAssertEqual(
            result.speakers,
            [
                SpeakerInfo(id: "L_SPEAKER_00", label: "Albert"),
                SpeakerInfo(id: "R_SPEAKER_00", label: "Speaker 2"),
            ])
        // Only names the tool knows are supplied; "Speaker 2" reads as
        // unnamed everywhere the app offers naming.
        XCTAssertEqual(result.suppliedLabels, ["L_SPEAKER_00": "Albert"])
        XCTAssertTrue(result.speakers[1].carriesAutomaticLabel)
        XCTAssertEqual(result.speakerCount, 2)
    }

    func testExcludedSpeakerAndTheirTurnsAreLeftOut() throws {
        let result = try ExternalDiarization.decode(Data(Self.sampleJSON.utf8)).result()

        XCTAssertFalse(result.speakers.contains { $0.id == "R_SPEAKER_01" })
        XCTAssertFalse(result.segments.contains { $0.speakerId == "R_SPEAKER_01" })
    }

    func testTurnOfAnUnlistedSpeakerIsIgnored() throws {
        let json = #"{"version": 1, "speakers": [{"id": "A"}], "turns": [{"speaker": "B", "start": 0, "end": 1}]}"#

        let result = try ExternalDiarization.decode(Data(json.utf8)).result()

        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testUnsupportedVersionIsRejected() {
        let json = #"{"version": 2, "speakers": [], "turns": []}"#

        XCTAssertThrowsError(try ExternalDiarization.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ExternalDiarization.ParseError, .unsupportedVersion(2))
        }
    }

    func testMissingFileNamesThePathItExpected() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try ExternalDiarization.load(fromFolder: folder)) { error in
            guard case .missing(let path) = error as? ExternalDiarization.ParseError else {
                return XCTFail("Expected missing, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix("diarization.json"))
        }
    }

    /// The shape `paraspeakrs agent diarize` writes.
    static let sampleJSON = """
        {
          "version": 1,
          "job_id": "job",
          "source": "/tmp/system.wav",
          "duration_seconds": 12.0,
          "speakers": [
            {"id": "L_SPEAKER_00", "label": "Albert", "label_source": "suggestion",
             "suggested_label": "Albert", "suggestion_score": 0.77,
             "sample_file": "L_SPEAKER_00__Albert_0.77.wav", "talk_seconds": 4.0, "excluded": false},
            {"id": "R_SPEAKER_00", "label": null, "label_source": null,
             "suggested_label": null, "suggestion_score": null,
             "sample_file": "R_SPEAKER_00__NAME-ME.wav", "talk_seconds": 0.9, "excluded": false},
            {"id": "R_SPEAKER_01", "label": "Gone", "label_source": "named",
             "sample_file": null, "talk_seconds": 2.0, "excluded": true}
          ],
          "turns": [
            {"speaker": "L_SPEAKER_00", "start": 1.752, "end": 4.232},
            {"speaker": "R_SPEAKER_01", "start": 5.0, "end": 7.0},
            {"speaker": "R_SPEAKER_00", "start": 8.4, "end": 9.3},
            {"speaker": "L_SPEAKER_00", "start": 10.0, "end": 11.5}
          ]
        }
        """
}
