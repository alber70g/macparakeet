# External meeting transcriber (paraspeakrs)

> Status: **IN PROGRESS** · Branch `feat/external-transcriber` · Fork remote `fork`
> Decisions taken with the owner on 2026-10-16 (turn-based discovery).

## Goal

Let a meeting be transcribed by a user-configured command instead of the
built-in STT. The command receives the meeting audio and writes a
`transcript.json` with words, timings and speakers. `paraspeakrs` is the first
supported tool and ships as a preset. Speakers are named in the meeting view:
play a sample, type a name, confirm a voice-library suggestion, merge or drop.
Names are written back to paraspeakrs so its voice library learns.

## Decisions

| Topic | Decision |
| --- | --- |
| Contract | Audio in, `transcript.json` out. Generic shell command template + paraspeakrs preset. |
| Scope | Milestone 1: meetings (recorded and imported). Milestone 2: file/URL transcription. Dictation is out of scope. |
| Trigger | Replaces the built-in STT and diarization when enabled. |
| Failure | Meeting stays in Error with audio and lock kept. Retry runs the external command again; the meeting can be retranscribed with the built-in engine. |
| Timing data | paraspeakrs adds a documented `transcript.json` (segments, words, start/end, speakers). Committed to paraspeakrs `master`; local tool reinstalled. |
| Naming | Meeting view: sample playback, rename, confirm suggestion, merge, drop. |
| Write-back | MacParakeet renames sample files with the paraspeakrs filename protocol and runs the apply command. |
| Suggestions | Initial label is the suggested name, with a "suggested NN%" badge and a Confirm action. |
| Samples | Kept in the meeting folder until the meeting is deleted; audio retention does not remove them. |
| Config | Settings UI + `macparakeet-cli config` keys. |
| Delivery | Branch pushed to the `alber70g/macparakeet` fork. |

## Contract summary

Command environment: `MACPARAKEET_AUDIO` (meeting playback audio),
`MACPARAKEET_OUT_DIR` (new empty folder `<meeting>/external-transcript/`),
`MACPARAKEET_MEETING_ID`. The template is run by the login shell through
`LocalCLIExecutor`; paths are never substituted into the command string.

paraspeakrs preset:

- transcribe: `paraspeakrs agent transcribe "$MACPARAKEET_AUDIO" -o "$MACPARAKEET_OUT_DIR" --sherpa-precision fp32`
- apply: `paraspeakrs agent apply "$MACPARAKEET_OUT_DIR"`

`transcript.json` v1 is defined in `spec/contracts/external-transcriber-v1.md`.

## Write-back rule

For each external speaker ID, the target sample file name is derived from the
effective MacParakeet roster:

1. Speaker removed by Drop → file moved to `dropped/` (restorable on Undo).
2. Speaker merged into another → `ID__<target label>.wav`.
3. Label equals the untouched suggestion and the file still has the suggestion
   stem → keep (accepted, library not taught).
4. Automatic label (`Speaker N`) → `ID__NAME-ME.wav`.
5. Otherwise → `ID__<label>.wav` (named, library taught). Confirm renames the
   suggestion file to this form.

Then the apply command runs. Failure is shown on the meeting; the MacParakeet
correction stays.

## Tasks

1. paraspeakrs: write `transcript.json` from `agent transcribe` and `agent apply`; tests; guide; changelog; reinstall.
2. Core: configuration + store keys; runner on `LocalCLIExecutor`; `transcript.json` parser; integration in `transcribeMeetingAudio`.
3. Core: write-back service; sample lookup; retention exclusion check.
4. App: Settings section; meeting speaker panel (play, confirm, merge, drop); Retry with built-in engine.
5. CLI: config keys; CHANGELOG; `integrations/README.md`.
6. Docs: ADR-035, contract, meeting-artifacts-v1 folder entry, `spec/02-features.md`.
7. Verification: focused tests, real paraspeakrs run on a local meeting, full suite once, push to fork.

## Milestone 2

File/URL transcription through the same runner and parser.
