import AVFoundation
import MacParakeetCore
import SwiftUI

/// Speaker overview controls for a transcription whose speakers an external detector found
/// (ADR-035): play the speaker's sample, and confirm a voice-library
/// suggestion so the tool learns the voice.
struct ExternalSpeakerControls: View {
    let speaker: ExternalSpeakerNaming.Speaker
    let isBusy: Bool
    let onConfirm: () -> Void

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if let sampleURL = speaker.sampleURL, !speaker.isDropped {
                Button {
                    togglePlayback(sampleURL)
                } label: {
                    Label(isPlaying ? "Stop sample" : "Play sample", systemImage: isPlaying ? "stop.fill" : "play.fill")
                }
                .parakeetAction(.secondary)
                .controlSize(.small)
                .help("Listen to a few takes of this speaker, separated by a beep.")
            }

            if speaker.hasUnconfirmedSuggestion, let score = speaker.suggestionScore {
                Text("Suggested · \(Int((score * 100).rounded()))%")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .help("The voice library guessed this name. Confirm it to teach the library this voice.")
                Button("Confirm", action: onConfirm)
                    .parakeetAction(.secondary)
                    .controlSize(.small)
                    .disabled(isBusy)
            }
        }
        .onDisappear { stop() }
    }

    private func togglePlayback(_ url: URL) {
        if isPlaying {
            stop()
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.play()
        isPlaying = true
        let duration = player.duration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            if self.player === player { stop() }
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

/// Write-back progress and failure under the speaker overview.
struct ExternalSpeakerWriteBackStatus: View {
    let isWriting: Bool
    let error: String?

    var body: some View {
        if isWriting {
            Label("Sending names to the speaker detection tool…", systemImage: "arrow.triangle.2.circlepath")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        } else if let error {
            Label(
                "Names were saved here but not sent to the speaker detection tool: \(error)",
                systemImage: "exclamationmark.triangle"
            )
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.warningAmber)
            .textSelection(.enabled)
        }
    }
}
