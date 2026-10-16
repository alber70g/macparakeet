import Foundation
import XCTest
@testable import MacParakeetCore

/// The runner executes a user command against meeting audio. These tests run
/// real shell commands to pin the contract a tool sees: inputs arrive only as
/// environment variables, the output folder starts empty, and failures carry
/// the tool's own explanation.
final class ExternalTranscriberRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // A space and shell syntax in the path: a command must never see them
        // as anything but data.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalTranscriberRunnerTests \(UUID().uuidString) $(touch INJECTED)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCommandReceivesPathsThroughEnvironmentAndResultIsRead() async throws {
        let audio = root.appendingPathComponent("meeting playback.m4a")
        try Data("audio".utf8).write(to: audio)
        let output = root.appendingPathComponent("external-transcript")
        let meetingID = UUID()
        let command = """
        test -f "$MACPARAKEET_AUDIO" && test "$MACPARAKEET_MEETING_ID" = "\(meetingID.uuidString)" \
        && printf '%s' '{"version":1,"speakers":[{"id":"A"}],"segments":[{"speaker":"A","start":0,"end":1,"text":"Hi","words":[{"word":"Hi","start":0,"end":1}]}]}' \
        > "$MACPARAKEET_OUT_DIR/transcript.json"
        """

        let transcript = try await ExternalTranscriberRunner().transcribe(
            audioURL: audio,
            outputFolder: output,
            meetingID: meetingID,
            configuration: ExternalTranscriberConfiguration(enabled: true, command: command, timeoutSeconds: 30)
        )

        // `test -f` passing proves the path with a space and `$(...)` arrived
        // byte for byte instead of being split or evaluated.
        XCTAssertEqual(transcript.segments.map(\.text), ["Hi"])
    }

    func testOutputFolderOfAnEarlierAttemptIsReplaced() async throws {
        let output = root.appendingPathComponent("external-transcript")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: output.appendingPathComponent("stale.wav"))
        // paraspeakrs refuses a non-empty folder; the retry must start clean.
        let command = #"test -z "$(ls -A "$MACPARAKEET_OUT_DIR")" && printf '{"version":1,"speakers":[],"segments":[]}' > "$MACPARAKEET_OUT_DIR/transcript.json""#

        _ = try await ExternalTranscriberRunner().transcribe(
            audioURL: root.appendingPathComponent("a.m4a"),
            outputFolder: output,
            meetingID: UUID(),
            configuration: ExternalTranscriberConfiguration(enabled: true, command: command, timeoutSeconds: 30)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("stale.wav").path))
    }

    func testFailureCarriesTheEndOfStderr() async throws {
        let command = #"echo "progress line" >&2; echo "error: model missing" >&2; exit 2"#

        do {
            _ = try await ExternalTranscriberRunner().transcribe(
                audioURL: root.appendingPathComponent("a.m4a"),
                outputFolder: root.appendingPathComponent("out"),
                meetingID: UUID(),
                configuration: ExternalTranscriberConfiguration(enabled: true, command: command, timeoutSeconds: 30)
            )
            XCTFail("Expected a failure")
        } catch let error as ExternalTranscriberError {
            guard case .commandFailed(let detail) = error else { return XCTFail("Got \(error)") }
            XCTAssertTrue(detail.contains("exit code 2"))
            XCTAssertTrue(detail.contains("error: model missing"))
        }
    }

    func testMissingTranscriptIsAnError() async {
        do {
            _ = try await ExternalTranscriberRunner().transcribe(
                audioURL: root.appendingPathComponent("a.m4a"),
                outputFolder: root.appendingPathComponent("out"),
                meetingID: UUID(),
                configuration: ExternalTranscriberConfiguration(enabled: true, command: "true", timeoutSeconds: 30)
            )
            XCTFail("Expected a failure")
        } catch {
            guard case .missing = error as? ExternalTranscript.ParseError else { return XCTFail("Got \(error)") }
        }
    }

    func testStderrTailKeepsTheLastLines() {
        let stderr = (1...20).map { "line \($0)" }.joined(separator: "\n")

        let tail = ExternalTranscriberRunner.tail(of: stderr)

        XCTAssertTrue(tail.hasPrefix("line 9"))
        XCTAssertTrue(tail.hasSuffix("line 20"))
    }

    func testConfigurationDefaultsAreDisabledAndTimeoutIsClamped() {
        XCTAssertFalse(ExternalTranscriberConfiguration().isActive)
        XCTAssertFalse(ExternalTranscriberConfiguration(enabled: true, command: "  ").isActive)
        XCTAssertEqual(ExternalTranscriberConfiguration(timeoutSeconds: 1).timeoutSeconds, 60)
        XCTAssertEqual(
            ExternalTranscriberConfiguration(command: ExternalTranscriberPreset.paraspeakrs.command).commandName,
            "paraspeakrs"
        )
    }
}
