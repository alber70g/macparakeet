# External Transcriber v1

> Status: ACTIVE - meetings (milestone 1). Decision record:
> [ADR-035](../adr/035-external-meeting-transcriber.md).

## Purpose

Define what a user-configured transcription command receives, what it must
write, and how MacParakeet writes speaker names back to it. paraspeakrs
(`paraspeakrs agent transcribe` / `agent apply`, version with
`transcript.json`) is the reference implementation and ships as a preset.

## Producers And Consumers

- `ExternalTranscriberRunner` (Core) runs the transcribe and apply commands
  through `LocalCLIExecutor.runCommand`.
- `TranscriptionService.transcribeMeetingAudio` imports the result through
  `ExternalTranscript.imported()`.
- `ExternalSpeakerNaming` and `ExternalSpeakerWriteBack` read the output
  folder and move sample files; `TranscriptionViewModel` triggers write-back
  after committed speaker corrections.
- Settings and `macparakeet-cli config` write the configuration keys.

## Configuration

| UserDefaults key | CLI key | Meaning |
| --- | --- | --- |
| `externalTranscriberEnabled` | `external-transcriber-enabled` | Default off. |
| `externalTranscriberCommand` | `external-transcriber-command` | Transcribe command; empty disables the path. |
| `externalTranscriberApplyCommand` | `external-transcriber-apply-command` | Optional; empty disables write-back. |
| `externalTranscriberTimeoutSeconds` | `external-transcriber-timeout` | 60–14400, default 1800. Applies to each command run. |

The CLI value `paraspeakrs` selects the preset command for either command key.

## Command environment

| Variable | Transcribe | Apply |
| --- | --- | --- |
| `MACPARAKEET_AUDIO` | Meeting playback audio (`meeting-playback.m4a`) | — |
| `MACPARAKEET_OUT_DIR` | New, empty `<meeting folder>/external-transcript/` | Same folder |
| `MACPARAKEET_MEETING_ID` | Meeting UUID | Meeting UUID |

Stdin is empty. Stdout is ignored. Exit code 0 means success; otherwise the
last 12 lines of stderr become the meeting's error message. An earlier
`external-transcript/` folder is removed before the transcribe command runs.

## transcript.json (version 1)

Required: `version` (must be `1`), `speakers`, `segments`. Unknown keys are
ignored. Times are seconds.

- `speakers[]`: `id` (required), `label`, `label_source`
  (`named` | `suggestion` | null), `suggested_label`, `suggestion_score`,
  `sample_file` (relative to the output folder), `excluded`.
- `segments[]`: `speaker` (an `id`, or null when unattributed), `start`, `end`,
  `text`, `words[]` with `word`, `start`, `end`.

Import rules:

- Speaker IDs become `external:<id>`. A null or unknown speaker, or an
  `excluded` one, leaves its words unattributed.
- Roster order follows `speakers`; only speakers with words appear. The label
  is `label`, else `Speaker N` (N = position in `speakers`, starting at 1).
- A segment with no words becomes one token spanning the segment; word timings
  are never invented.

## Sample file names (write-back)

The part after `<id>__` in a top-level `.wav` file name is the speaker's name.
`NAME-ME` means unnamed. A suggestion file is `<id>__<label>_<score with two
decimals>.wav`. Dropped samples are moved to `dropped/`, which the tool does
not read. Name characters follow paraspeakrs: `/` becomes `-`, NUL is removed,
whitespace is trimmed. The rules that choose each name are in ADR-035.

## Non-stable details

Settings copy, progress phases, log lines and the exact error wording.

## Versioning And Compatibility

A `transcript.json` with another `version` is rejected with an error naming
both versions. New optional fields are additive. Removing a field, changing
time units, or changing the filename protocol requires version 2.

## Tests that enforce this

- `ExternalTranscriptTests` — parsing and import rules.
- `ExternalTranscriberRunnerTests` — environment-only inputs, fresh folder,
  stderr tail, configuration bounds.
- `ExternalSpeakerNamingTests` — write-back rules against real corrections.
- `TranscriptionServiceExternalTranscriberTests` — replacement of built-in STT,
  Error without fallback, explicit-engine bypass.
- `ConfigCommandTests.testExternalTranscriberConfigIsWhatTheAppReads`.

## When this changes

Update this contract, ADR-035, the paraspeakrs agent guide when the shared
schema changes, and the focused tests above in the same change.
