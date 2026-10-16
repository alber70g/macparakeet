import MacParakeetCore
import SwiftUI

/// Settings, Engine tab: which detector finds the speakers (ADR-035). The
/// Capture tab's "Speaker detection" toggles still decide whether detection
/// runs for meetings and for file transcriptions. Stored in the UserDefaults
/// keys `macparakeet-cli config` reads and writes.
struct SpeakerDetectionSettingsCard: View {
    @AppStorage(ExternalDiarizerConfiguration.enabledKey) private var external = false
    @AppStorage(ExternalDiarizerConfiguration.commandKey) private var command = ""
    @AppStorage(ExternalDiarizerConfiguration.applyCommandKey) private var applyCommand = ""
    @AppStorage(ExternalDiarizerConfiguration.timeoutSecondsKey)
    private var timeoutSeconds = ExternalDiarizerConfiguration.defaultTimeoutSeconds

    var body: some View {
        SettingsCard(
            title: "Speaker Detection",
            subtitle: "Finds who said what in meetings and file transcriptions. "
                + "Turn it on or off for each in the Capture tab.",
            icon: "person.2.wave.2",
            status: missingCommand ? SettingsCardStatus(.required, label: "Command needed") : nil
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(alignment: .center) {
                    Text("Detector")
                        .font(DesignSystem.Typography.body)
                    Spacer(minLength: DesignSystem.Spacing.md)
                    Picker("Detector", selection: $external) {
                        Text("Built-in").tag(false)
                        Text("External command").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }

                if external {
                    externalOptions
                } else {
                    Text("Runs on this Mac with MacParakeet's own speaker models.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var missingCommand: Bool {
        external && command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var externalOptions: some View {
        Text(
            "MacParakeet still recognizes the words; your command only finds the speakers. "
                + "It writes diarization.json and one audio sample per speaker, which you can play "
                + "and name in the transcript. If it fails, the transcript is kept without speakers. "
                + "An exact speaker count in Retranscribe uses the built-in detector."
        )
        .font(DesignSystem.Typography.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(ExternalDiarizerPreset.allCases, id: \.self) { preset in
                Button("Use \(preset.displayName)") {
                    command = preset.command
                    applyCommand = preset.applyCommand
                }
                .parakeetAction(.secondary)
            }
            Spacer()
        }

        commandField(
            title: "Detect command",
            detail: "Runs in your login shell. Read the audio path from $MACPARAKEET_AUDIO and write "
                + "diarization.json and the samples into $MACPARAKEET_OUT_DIR.",
            text: $command
        )

        commandField(
            title: "Apply names command (optional)",
            detail: "Runs after you name, merge or drop a speaker, so the tool can learn the voices. "
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
                    set: { timeoutSeconds = ExternalDiarizerConfiguration.clampedTimeout($0 * 60) }
                ),
                in: (ExternalDiarizerConfiguration.minimumTimeoutSeconds / 60)...(ExternalDiarizerConfiguration
                    .maximumTimeoutSeconds / 60),
                step: 5
            )
            .fixedSize()
        }

        if missingCommand {
            Text("Enter a detect command. Until then, the built-in detector is used.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.warningAmber)
        }
    }

    private func commandField(title: String, detail: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(title)
                .font(DesignSystem.Typography.body)
            TextField(title, text: text, axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            Text(detail)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
