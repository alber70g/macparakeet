import Foundation
import XCTest
@testable import MacParakeetCore

/// Runs the real paraspeakrs preset (ADR-035). Opt-in: needs paraspeakrs on
/// the login-shell PATH and a speech recording.
///
///     MACPARAKEET_PARASPEAKRS_E2E_AUDIO=/path/to/conversation.wav \
///     swift test --filter ExternalDiarizerParaspeakrsE2ETests
///
/// The run uses a throwaway paraspeakrs workspace, so the user's voice
/// library and jobs are not touched.
final class ExternalDiarizerParaspeakrsE2ETests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalDiarizerParaspeakrsE2E-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDiarizeNameAndRerunKeepsTheName() async throws {
        let audioPath = ProcessInfo.processInfo.environment["MACPARAKEET_PARASPEAKRS_E2E_AUDIO"] ?? ""
        try XCTSkipIf(
            audioPath.isEmpty,
            "Set MACPARAKEET_PARASPEAKRS_E2E_AUDIO to a recording to run the real paraspeakrs check."
        )
        let workspace = root.appendingPathComponent("paraspeakrs-workspace")
        let isolate = #" --workspace-dir "\#(workspace.path)""#
        let configuration = ExternalDiarizerConfiguration(
            enabled: true,
            command: ExternalDiarizerPreset.paraspeakrs.command + isolate,
            applyCommand: ExternalDiarizerPreset.paraspeakrs.applyCommand + isolate,
            timeoutSeconds: 900
        )
        let runner = ExternalDiarizerRunner()
        // A temporary copy, deleted after the first run, as MacParakeet does.
        let firstCopy = root.appendingPathComponent("first.wav")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: audioPath), to: firstCopy)
        let firstOutput = root.appendingPathComponent("first-output")

        let first = try await runner.diarize(
            audioURL: firstCopy,
            outputFolder: firstOutput,
            transcriptionID: UUID(),
            configuration: configuration
        )
        let result = first.result()
        XCTAssertFalse(result.segments.isEmpty, "paraspeakrs found no speech")
        let naming = try XCTUnwrap(ExternalSpeakerNaming.load(outputFolder: firstOutput))
        XCTAssertEqual(naming.speakers.count, first.speakers.count)
        XCTAssertTrue(naming.speakers.allSatisfy { $0.sampleURL != nil }, "Every speaker needs a playable sample")

        // Name the first speaker the way write-back does, then apply.
        let speaker = try XCTUnwrap(naming.speakers.first)
        try naming.applyFileMoves([speaker.externalID: .named("Test Person")])
        try await runner.apply(outputFolder: firstOutput, transcriptionID: UUID(), configuration: configuration)
        let applied = try ExternalDiarization.load(fromFolder: firstOutput)
        XCTAssertEqual(applied.speakers.first { $0.id == speaker.externalID }?.label, "Test Person")

        // Rerunning the same audio from a new temporary copy brings the name back.
        try FileManager.default.removeItem(at: firstCopy)
        let secondCopy = root.appendingPathComponent("second.wav")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: audioPath), to: secondCopy)
        let second = try await runner.diarize(
            audioURL: secondCopy,
            outputFolder: root.appendingPathComponent("second-output"),
            transcriptionID: UUID(),
            configuration: configuration
        ).result()
        XCTAssertEqual(second.suppliedLabels[speaker.externalID], "Test Person")
    }
}
