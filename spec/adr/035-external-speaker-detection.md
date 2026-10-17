# ADR-035: External speaker detection

**Status:** Accepted  
**Date:** 2026-10-17

## Context

Some users already run a local tool that detects speakers better for their
recordings than the built-in diarizer. `paraspeakrs` is the first case: it
separates speakers per stereo channel and keeps a voice library that names
known speakers across recordings. Its agent interface is a folder of
per-speaker sample WAV files whose names carry the speaker names
(`<ID>__<Name>.wav`) plus an `apply` command that reads them back.

Users want that tool to find the speakers inside MacParakeet, and to name
speakers in the transcript view instead of in Finder. MacParakeet's speech
recognition is not the problem being solved: running a second ASR pass in the
tool would cost minutes per meeting and a second multi-gigabyte model.
Building cross-recording speaker identity into MacParakeet would duplicate a
tool the user already maintains; MacParakeet's own voice profiles remain
experimental and disabled by default.

## Decision

### A command replaces the built-in diarizer

Settings → Engine → Speaker Detection chooses the detector: **Built-in** (the
default) or **External command**. The Capture tab's two "Speaker detection"
toggles still decide whether detection runs for meetings and for file and URL
transcriptions. MacParakeet always recognizes the words itself.

- The choice is read on every run (`SelectableDiarizationService`, returned by
  `DiarizationServiceFactory.live`), so it applies to the next transcription
  without a restart, in the app and in `macparakeet-cli`.
- The command runs through `LocalCLIExecutor` in the user's login shell, with
  the shell PATH the local-CLI LLM provider already discovers.
- Inputs are environment variables only: `MACPARAKEET_AUDIO`,
  `MACPARAKEET_OUT_DIR` (a fresh, empty folder) and
  `MACPARAKEET_TRANSCRIPTION_ID`. Paths are never substituted into the
  command string.
- For a meeting, `MACPARAKEET_AUDIO` is `meeting-playback.m4a`: the whole
  meeting in stereo, microphone on one side and system audio on the other, on
  the transcript's timeline. The built-in diarizer only splits the system side
  and labels the microphone "Me"; that fails for people in the same room, who
  all speak into the microphone. paraspeakrs diarizes each stereo side, so it
  finds them. For a file transcription it is the converted WAV.
- The command writes `diarization.json` (contract:
  [external-diarizer-v1](../contracts/external-diarizer-v1.md)): speakers
  and their turns. MacParakeet assigns its own words to those turns with the
  built-in merge rules. In a meeting this covers microphone and system words
  alike; speakers are stored as `external:<id>`, and a word no turn covers
  keeps its source (`microphone` as "Me", `system` as "Unattributed").
- A speaker the tool already knows by name (a voice-library match or an
  earlier naming) keeps that name. Other speakers are "Speaker N".
- With the external command selected, the built-in speaker models are not
  prepared or downloaded.
- The paraspeakrs preset runs `paraspeakrs agent diarize`, which runs no ASR.

### Output location

- Meetings: `<meeting folder>/speaker-detection/`, deleted with the meeting.
- File and URL transcriptions:
  `<app support>/speaker-detection/<transcription id>/`, deleted with the
  transcription.

A run with the built-in detector removes an earlier run's folder, because its
samples would no longer match the new speakers.

### Failure keeps the transcript

Speaker detection stays optional, as for the built-in diarizer: a non-zero
exit, timeout or unreadable `diarization.json` completes the transcript
without speaker labels. The error is written to
`speaker-detection/macparakeet-error.txt` and shown in the transcript view with
"Retranscribe to try again". MacParakeet does not fall back to the built-in
diarizer.

An explicit speaker count (the Retranscribe popover's Exact option, CLI
`--speaker-count`, `--speaker-min`, `--speaker-max`) uses the built-in
diarizer, because the external contract has no count. Auto uses the selected
detector.

### Speaker naming and write-back

The transcript view offers, per speaker the tool found, sample playback, the
existing rename and merge actions, Confirm for an untouched voice-library
suggestion, and Drop. Drop omits the speaker's lines and removes the speaker
through ordinary correction commands, so Undo restores both.

After every committed speaker correction, Undo and Redo, MacParakeet derives
each sample file's name from the effective speaker roster:

1. No remaining lines → the sample moves to `speaker-detection/dropped/`.
2. Lines reassigned to another speaker (merge) → `<ID>__<that label>.wav`.
3. Untouched suggestion → the file is left as is (the library is not taught).
4. Automatic label → `<ID>__NAME-ME.wav`.
5. Otherwise → `<ID>__<label>.wav` (the library is taught).

If any file moved, the configured apply command runs. Write-backs run one at a
time in commit order. A failed write-back is shown under the speaker overview;
the MacParakeet correction is kept. The correction journal stays the source of
truth for MacParakeet; the folder is the source of truth for the tool.

## Consequences

- Speaker detection can come from a tool the user controls, without a new
  diarization backend in MacParakeet.
- Audio stays local unless the user's own command sends it elsewhere. That
  command is an explicit user choice, like the local-CLI LLM provider.
- External speakers carry no MacParakeet embeddings, so voice-profile scoring
  does not apply to them; the tool's own voice library names them instead.
- Names the user gives in MacParakeet reach the tool's voice library, and the
  next recording of the same voice arrives with a suggestion.

## Alternatives considered

- **A command that replaces transcription and diarization.** Built first on
  a separate branch: the tool's ASR ran a second time, and the meeting failed
  when the command failed.
- **Fire-and-forget post-meeting hook (existing).** It cannot return speakers
  and has a 300-second ceiling.
- **Read paraspeakrs's internal job files.** No paraspeakrs change, but breaks
  when its internals change; paraspeakrs instead added a documented
  `agent diarize` and `diarization.json`.
