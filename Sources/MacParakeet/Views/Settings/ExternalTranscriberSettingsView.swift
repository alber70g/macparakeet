import MacParakeetCore
import SwiftUI

/// Settings: external meeting transcriber (ADR-035). A shell command replaces
/// built-in meeting transcription and speaker detection. Stored in the same
/// UserDefaults keys `macparakeet-cli config` reads and writes.
struct ExternalTranscriberSettingsView: View {
    @AppStorage(ExternalTranscriberConfiguration.enabledKey) private var enabled = false
    @AppStorage(ExternalTranscriberConfiguration.commandKey) private var command = ""
    @AppStorage(ExternalTranscriberConfiguration.applyCommandKey) private var applyCommand = ""
    @AppStorage(ExternalTranscriberConfiguration.timeoutSecondsKey)
    private var timeoutSeconds = ExternalTranscriberConfiguration.defaultTimeoutSeconds

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            SettingsToggleRow(
                title: "Transcribe meetings with an external command",
                detail: "Runs your command on the meeting audio instead of the built-in engine and speaker "
                    + "detection. The command writes transcript.json with words, times and speakers. "
                    + "If it fails, the meeting shows an error and can be retried.",
                isBeta: true,
                isOn: $enabled
            )

            if enabled {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text("Preset")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                    ForEach(ExternalTranscriberPreset.allCases, id: \.self) { preset in
                        Button("Use \(preset.displayName)") {
                            command = preset.command
                            applyCommand = preset.applyCommand
                        }
                        .parakeetAction(.secondary)
                    }
                    Spacer()
                }

                commandField(
                    title: "Transcribe command",
                    detail: "Runs in your login shell. Read the audio path from $MACPARAKEET_AUDIO and "
                        + "write transcript.json into $MACPARAKEET_OUT_DIR.",
                    text: $command
                )

                commandField(
                    title: "Apply names command (optional)",
                    detail: "Runs after you name, merge or drop a speaker, so the tool can learn the names. "
                        + "Leave empty to keep names in MacParakeet only.",
                    text: $applyCommand
                )

                HStack {
                    Text("Time limit")
                        .font(DesignSystem.Typography.body)
                    Spacer()
                    Stepper(
                        "\(Int(timeoutSeconds / 60)) min",
                        value: Binding(
                            get: { timeoutSeconds / 60 },
                            set: { timeoutSeconds = ExternalTranscriberConfiguration.clampedTimeout($0 * 60) }
                        ),
                        in: (ExternalTranscriberConfiguration.minimumTimeoutSeconds / 60)...(ExternalTranscriberConfiguration
                            .maximumTimeoutSeconds / 60),
                        step: 5
                    )
                    .fixedSize()
                }

                if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a transcribe command. Until then, meetings use the built-in engine.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.warningAmber)
                }
            }
        }
    }

    private func commandField(title: String, detail: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DesignSystem.Typography.body)
            TextField(title, text: text, axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }
}
