import Foundation
import XCTest
@testable import MacParakeetCore

/// The runner executes a user command against transcription audio. These
/// tests run real shell commands to pin the contract a tool sees: inputs
/// arrive only as environment variables, the output folder starts empty, and
/// failures carry the tool's own explanation.
final class ExternalDiarizerRunnerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // A space and shell syntax in the path: a command must never see them
        // as anything but data.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalDiarizerRunnerTests \(UUID().uuidString) $(touch INJECTED)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCommandReceivesPathsThroughEnvironmentAndResultIsRead() async throws {
        let audio = root.appendingPathComponent("system audio.wav")
        try Data("audio".utf8).write(to: audio)
        let output = root.appendingPathComponent("speaker-detection")
        let transcriptionID = UUID()
        let command = """
            test -f "$MACPARAKEET_AUDIO" && test "$MACPARAKEET_TRANSCRIPTION_ID" = "\(transcriptionID.uuidString)" \
            && printf '%s' '{"version":1,"speakers":[{"id":"A"}],"turns":[{"speaker":"A","start":0,"end":1}]}' \
            > "$MACPARAKEET_OUT_DIR/diarization.json"
            """

        let diarization = try await ExternalDiarizerRunner().diarize(
            audioURL: audio,
            outputFolder: output,
            transcriptionID: transcriptionID,
            configuration: ExternalDiarizerConfiguration(enabled: true, command: command, timeoutSeconds: 60)
        )

        // `test -f` passing proves the path with a space and `$(...)` arrived
        // byte for byte instead of being split or evaluated.
        XCTAssertEqual(diarization.turns, [ExternalDiarization.Turn(speaker: "A", start: 0, end: 1)])
    }

    func testOutputFolderOfAnEarlierRunIsReplaced() async throws {
        let output = root.appendingPathComponent("speaker-detection")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: output.appendingPathComponent("stale.wav"))
        // paraspeakrs refuses a non-empty folder; a rerun must start clean.
        let command =
            #"test -z "$(ls -A "$MACPARAKEET_OUT_DIR")" && printf '{"version":1,"speakers":[],"turns":[]}' > "$MACPARAKEET_OUT_DIR/diarization.json""#

        _ = try await ExternalDiarizerRunner().diarize(
            audioURL: root.appendingPathComponent("a.wav"),
            outputFolder: output,
            transcriptionID: nil,
            configuration: ExternalDiarizerConfiguration(enabled: true, command: command, timeoutSeconds: 60)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("stale.wav").path))
    }

    func testFailureCarriesTheEndOfStderr() async throws {
        let command = #"echo "progress line" >&2; echo "error: model missing" >&2; exit 2"#

        do {
            _ = try await ExternalDiarizerRunner().diarize(
                audioURL: root.appendingPathComponent("a.wav"),
                outputFolder: root.appendingPathComponent("out"),
                transcriptionID: UUID(),
                configuration: ExternalDiarizerConfiguration(enabled: true, command: command, timeoutSeconds: 60)
            )
            XCTFail("Expected a failure")
        } catch let error as ExternalDiarizerError {
            guard case .commandFailed(let detail) = error else { return XCTFail("Got \(error)") }
            XCTAssertTrue(detail.contains("exit code 2"))
            XCTAssertTrue(detail.contains("error: model missing"))
        }
    }

    func testMissingDiarizationFileIsAnError() async {
        do {
            _ = try await ExternalDiarizerRunner().diarize(
                audioURL: root.appendingPathComponent("a.wav"),
                outputFolder: root.appendingPathComponent("out"),
                transcriptionID: UUID(),
                configuration: ExternalDiarizerConfiguration(enabled: true, command: "true", timeoutSeconds: 60)
            )
            XCTFail("Expected a failure")
        } catch {
            guard case .missing = error as? ExternalDiarization.ParseError else { return XCTFail("Got \(error)") }
        }
    }

    func testApplyRunsInTheOutputFolderContext() async throws {
        let output = root.appendingPathComponent("speaker-detection")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try await ExternalDiarizerRunner().apply(
            outputFolder: output,
            transcriptionID: UUID(),
            configuration: ExternalDiarizerConfiguration(
                enabled: true,
                command: "true",
                applyCommand: #"touch "$MACPARAKEET_OUT_DIR/applied""#,
                timeoutSeconds: 60
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("applied").path))
    }

    func testStderrTailKeepsTheLastLines() {
        let stderr = (1...20).map { "line \($0)" }.joined(separator: "\n")

        let tail = ExternalDiarizerRunner.tail(of: stderr)

        XCTAssertTrue(tail.hasPrefix("line 9"))
        XCTAssertTrue(tail.hasSuffix("line 20"))
    }

    func testConfigurationDefaultsAreDisabledAndTimeoutIsClamped() {
        XCTAssertFalse(ExternalDiarizerConfiguration().isActive)
        XCTAssertFalse(ExternalDiarizerConfiguration(enabled: true, command: "  ").isActive)
        XCTAssertEqual(ExternalDiarizerConfiguration(timeoutSeconds: 1).timeoutSeconds, 60)
        XCTAssertEqual(
            ExternalDiarizerConfiguration(command: ExternalDiarizerPreset.paraspeakrs.command).commandName,
            "paraspeakrs"
        )
    }

    /// The paraspeakrs preset must run diarization only: MacParakeet keeps
    /// recognizing the words, and a second ASR pass would cost minutes.
    func testParaspeakrsPresetRunsDiarizationOnly() {
        XCTAssertTrue(ExternalDiarizerPreset.paraspeakrs.command.contains("agent diarize"))
        XCTAssertFalse(ExternalDiarizerPreset.paraspeakrs.command.contains("transcribe"))
    }
}
