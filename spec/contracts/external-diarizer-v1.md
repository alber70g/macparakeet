# External Diarizer v1

> Status: ACTIVE. Decision record:
> [ADR-035](../adr/035-external-speaker-detection.md).

## Purpose

Define what a user-configured speaker-detection command receives, what it must
write, and how MacParakeet writes speaker names back to it. paraspeakrs
(`paraspeakrs agent diarize` / `agent apply`, version with `diarization.json`)
is the reference implementation and ships as a preset.

## Producers And Consumers

- `ExternalDiarizerRunner` (Core) runs the detect and apply commands through
  `LocalCLIExecutor.runCommand`.
- `ExternalDiarizationService` turns `diarization.json` into a
  `MacParakeetDiarizationResult`; `SelectableDiarizationService` picks it or
  the built-in diarizer per run. `TranscriptionService` passes each run's
  `DiarizationRunContext` (transcription ID and output folder).
- `ExternalSpeakerNaming` and `ExternalSpeakerWriteBack` read the output
  folder and move sample files; `TranscriptionViewModel` triggers write-back
  after committed speaker corrections.
- Settings (Engine → Speaker Detection) and `macparakeet-cli config` write the
  configuration keys.

## Configuration

| UserDefaults key | CLI key | Meaning |
| --- | --- | --- |
| `externalDiarizerEnabled` | `external-diarizer-enabled` | Default off. |
| `externalDiarizerCommand` | `external-diarizer-command` | Detect command; empty keeps the built-in diarizer. |
| `externalDiarizerApplyCommand` | `external-diarizer-apply-command` | Optional; empty disables write-back. |
| `externalDiarizerTimeoutSeconds` | `external-diarizer-timeout` | 60–14400, default 1800. Applies to each command run. |

The CLI value `paraspeakrs` selects the preset command for either command key;
`none` clears it.

## Command environment

The command runs as `zsh -lc <command>` with the login shell's PATH and an
empty stdin. Values arrive only as environment variables:

| Variable | Detect | Apply |
| --- | --- | --- |
| `MACPARAKEET_AUDIO` | Meetings: `<meeting folder>/meeting-playback.m4a`, the whole meeting in stereo (microphone on one side, system audio on the other), on the transcript's timeline. File transcriptions: the converted WAV, temporary and deleted after the run. | — |
| `MACPARAKEET_OUT_DIR` | New, empty output folder (below) | Same folder |
| `MACPARAKEET_TRANSCRIPTION_ID` | Transcription UUID (absent for runs without a saved transcription) | Transcription UUID |

Output folder:

- Meetings: `<meeting folder>/speaker-detection/`.
- File and URL transcriptions: `<app support>/speaker-detection/<transcription id>/`.

MacParakeet deletes and recreates the folder before each detect run. Exit code
0 means success; any other exit code fails the run, and the last 12 stderr
lines become the error shown in the transcript view.

## `diarization.json`

Times are seconds from the start of `MACPARAKEET_AUDIO`. Unknown keys are
ignored.

```json
{
  "version": 1,
  "speakers": [
    {
      "id": "SPEAKER_00",
      "label": "Alice",
      "label_source": "suggestion",
      "suggested_label": "Alice",
      "suggestion_score": 0.82,
      "sample_file": "SPEAKER_00__Alice_0.82.wav",
      "excluded": false
    }
  ],
  "turns": [
    { "speaker": "SPEAKER_00", "start": 1.25, "end": 4.5 }
  ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `version` | yes | Must be `1`; other versions fail the run. |
| `speakers[].id` | yes | Stable within this output. Must not contain `__`. |
| `speakers[].label` | no | Name to show: `named` (chosen by a person) or `suggestion` (voice-library guess). Null when unnamed. |
| `speakers[].suggested_label`, `suggestion_score` | no | An unconfirmed voice-library guess and its score (0–1). |
| `speakers[].sample_file` | no | Sample audio relative to the folder. |
| `speakers[].excluded` | no | `true` leaves the speaker and their turns out. |
| `turns[]` | yes | `speaker`, `start`, `end`. A turn of an unlisted or excluded speaker is ignored. Turns may overlap. |

MacParakeet assigns its own words to turns with the built-in merge rules. In
a meeting that covers microphone and system words alike; IDs are stored as
`external:<id>`, and a word no turn covers keeps its source id (`microphone`,
shown as "Me", or `system`, shown as "Unattributed"). File transcriptions
store the IDs unchanged. Speakers without turns are left out. A speaker with
a `label` keeps it; others are "Speaker N".

## Sample files and write-back

Samples follow the paraspeakrs naming protocol: `<id>__<name>.wav` at the
folder's top level, where `<name>` is `NAME-ME` (unnamed), a name, or
`<label>_<score with 2 decimals>` (an untouched suggestion). Write-back moves
files only:

| MacParakeet state | Sample file after write-back |
| --- | --- |
| Speaker has no remaining lines | `dropped/<id>__<current name>.wav` |
| Lines merged into another speaker | `<id>__<other speaker's label>.wav` |
| Untouched suggestion | unchanged |
| Automatic label (`Speaker N`, `Others N`) | `<id>__NAME-ME.wav` |
| Any other label | `<id>__<label>.wav` (`/` becomes `-`) |

Then the apply command runs if any file moved. A tool reads the folder's top
level as the current naming state; files in `dropped/` mean the speaker was
removed.

## Failure

| Failure | Result |
| --- | --- |
| Non-zero exit, timeout, missing or unreadable `diarization.json` | Transcript completes without speaker labels; error saved to `macparakeet-error.txt` in the folder and shown in the transcript view. No fallback to the built-in diarizer. |
| Apply command fails | MacParakeet correction kept; error shown under the speaker overview. |

## Tests

- `ExternalDiarizationTests`, `ExternalDiarizerRunnerTests`,
  `ExternalSpeakerNamingTests`, `TranscriptionServiceExternalDiarizationTests`
  in `Tests/MacParakeetTests/Services/Diarization/External/`.
- `ExternalDiarizerParaspeakrsE2ETests` runs the real paraspeakrs when
  `MACPARAKEET_PARASPEAKRS_E2E_AUDIO` names a recording.
- `ConfigCommandTests.testExternalDiarizerConfigIsWhatTheAppReads`.
