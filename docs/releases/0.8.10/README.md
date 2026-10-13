# MacParakeet 0.8.10

Preparation record for the 0.8.10 candidate. This is not a publication record. The stable download remains [0.8.9](../0.8.9/README.md) until the signed DMG, appcast, and GitHub release exist.

- [GitHub release body](github.md): changes since 0.8.9, the CLI 5.1.0 default-model note, and a link to 0.8.9 for people skipping that release.
- [Sparkle description](sparkle.html): 0.8.10 changes plus a short 0.8.9 recap. Sparkle shows only the newest item, so the recap has to stand alone. The feed should keep previous entries.

## Candidate

- Code base: `abef7e56bedb84dea8dbd90892f7e475b6361367` on `origin/main`. That commit includes the Unattributed speaker label (#1241), exact dictation-chord matching (#1242), and the live-preview memory bound (#1236).
- #1236's own CI passed before merge: tests, Swift 6, and the release bundle. The merge commit's [CI run](https://github.com/moona3k/macparakeet/actions/runs/38329495360) is the check for this exact base. Do not build the DMG from an older `release/0.8.10` commit.
- This preparation commit bumps the bundled CLI from 5.0.0 to 5.1.0 and adds these notes. Fill in the signed commit, build number, DMG size, and SHA-256 at publication. Do not copy the 0.8.9 artifact identity forward.

## Known limits

- [#1199](https://github.com/moona3k/macparakeet/issues/1199) is the 16 GB M2 Air / Teams memory report. Cleaned-mic rendering and the during-call preview backlog are bounded in this candidate. Those measurements do not close the Air report. Release notes describe the memory bounds and do not say the freeze is fixed.
- [#1228](https://github.com/moona3k/macparakeet/issues/1228) is fixed here. Older meetings keep their stored speaker labels until re-transcribed.
- [#920](https://github.com/moona3k/macparakeet/issues/920), [#912](https://github.com/moona3k/macparakeet/issues/912), and [#1214](https://github.com/moona3k/macparakeet/issues/1214) remain open and are already true of 0.8.9.
- If live preview falls behind, some live words may skip and later preview words can look early. The saved recording is kept.

## Gates

Voice Control, cross-recording Ask, voice profiles, encrypted share links, and in-process MLX stay off in release builds. **0.9.0** stays reserved for qualified Voice Control.

The app and CLI both default Anthropic to `claude-sonnet-5-5` and OpenRouter to `anthropic/claude-sonnet-5.5`. New Summary prompts include meeting notes in both surfaces; existing libraries keep their saved preference. Meeting URL controls default off in the app and are not a CLI command. Diarized meetings label unclaimed system words Unattributed and leave them out of `speakerCount` in both surfaces.

## Not yet verified

Signed app and DMG notarization, stapling, Gatekeeper, the mounted CLI version, a Sparkle upgrade, website changelog deployment, and physical microphone, Bluetooth, or 16 GB capture. Those belong to the publication steps in [distribution](../../distribution.md).
