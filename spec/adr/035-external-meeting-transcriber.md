# ADR-035: External meeting transcriber

**Status:** Accepted (milestone 1: meetings)  
**Date:** 2026-10-16

## Context

Some users already run a local transcription tool that does more than the
built-in pipeline for their meetings. `paraspeakrs` is the first case: it
transcribes with Parakeet, separates speakers per stereo channel, and keeps a
voice library that names known speakers across recordings. Its agent interface
is a folder of per-speaker sample WAV files whose names carry the speaker names
(`<ID>__<Name>.wav`) plus an `apply` command that reads them back.

Users want such a tool to produce the meeting transcript inside MacParakeet,
and to name speakers in the meeting view instead of in Finder. Building
cross-meeting speaker identity into MacParakeet would duplicate a tool the
user already maintains; MacParakeet's own voice profiles remain experimental
and disabled by default.

## Decision

### A command replaces built-in meeting STT

When enabled, a user-configured shell command replaces built-in meeting STT
and diarization for recorded and imported meetings. It is disabled by default
and has no effect until a command is set.

- The command runs through `LocalCLIExecutor` in the user's login shell, with
  the shell PATH that the local-CLI LLM provider already discovers.
- Inputs are environment variables only: `MACPARAKEET_AUDIO` (the meeting's
  playback audio), `MACPARAKEET_OUT_DIR` (a fresh, empty
  `<meeting folder>/external-transcript/`) and `MACPARAKEET_MEETING_ID`.
  Paths are never substituted into the command string.
- The command writes `transcript.json` (contract:
  [external-transcriber-v1](../contracts/external-transcriber-v1.md)).
  MacParakeet imports its words, timings and speakers as the meeting's
  automatic transcript. Vocabulary corrections, segments, search indexing,
  artifacts and saved-audio automation then run as for built-in meetings.
- `Transcription.engine` is `external`; `engineVariant` is the command's first
  word.

### Failure leaves the meeting in Error

A non-zero exit, timeout or unreadable `transcript.json` leaves the meeting in
the ordinary Error state with its audio and recovery lock. MacParakeet does
not silently fall back to another engine. Retry and retranscribe without an
engine choice run the command again. Choosing a built-in engine explicitly in
the retranscribe menu (or `macparakeet-cli retranscribe`, which always resolves
an engine) bypasses the command.

### Speaker naming and write-back

External speaker IDs are stored as `external:<ID>` so they never collide with
the built-in `microphone`/`system` roster semantics. A speaker's initial label
is the tool's label: a name, a voice-library suggestion, or `Speaker N`.

The meeting view offers, per external speaker, sample playback, the existing
rename and merge actions, Confirm for an untouched suggestion, and Drop.
Drop omits the speaker's lines and removes the speaker through ordinary
correction commands, so Undo restores both.

After every committed speaker correction, Undo and Redo, MacParakeet derives
each sample file's name from the effective speaker roster:

1. No remaining lines → the sample moves to `external-transcript/dropped/`.
2. Lines reassigned to another speaker (merge) → `<ID>__<that label>.wav`.
3. Untouched suggestion → the file is left as is (the library is not taught).
4. Automatic label → `<ID>__NAME-ME.wav`.
5. Otherwise → `<ID>__<label>.wav` (the library is taught).

If any file moved, the configured apply command runs. Write-backs run one at a
time in commit order. A failed write-back is shown under the speaker overview;
the MacParakeet correction is kept. The correction journal stays the source of
truth for MacParakeet; the folder is the source of truth for the tool.

### Retention

Samples stay in the meeting folder until the meeting is deleted. Meeting-audio
retention removes only the managed audio files and does not touch
`external-transcript/`.

## Consequences

- Meeting transcripts can come from a tool the user controls, without a new
  STT engine family in MacParakeet (ADR-026 is unchanged: this is not a
  bundled engine).
- Audio stays local unless the user's own command sends it elsewhere. That
  command is an explicit user choice, like the local-CLI LLM provider.
- The external path skips built-in diarization and voice-profile scoring for
  that meeting.
- Milestone 2: file and URL transcription through the same runner and parser.
  Dictation is out of scope; a command per utterance is too slow.

## Alternatives considered

- **Fire-and-forget post-meeting hook (existing).** It cannot return a
  transcript and has a 300-second ceiling.
- **Text-in/text-out post-processor.** Cannot provide speakers or timings, and
  paraspeakrs needs audio.
- **Read paraspeakrs's internal job files.** No paraspeakrs change, but breaks
  when its internals change; paraspeakrs instead added a documented
  `transcript.json`.
