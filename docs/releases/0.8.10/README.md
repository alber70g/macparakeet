# MacParakeet 0.8.10

Preparation record for the 0.8.10 candidate. This is not a publication record. The stable download remains [0.8.9](../0.8.9/README.md) until the signed DMG, appcast, and GitHub release exist.

- [GitHub release body](github.md): changes since 0.8.9, the CLI 5.1.0 default-model note, and a link to 0.8.9 for people skipping that release.
- [Sparkle description](sparkle.html): 0.8.10 changes plus a short 0.8.9 recap. Sparkle shows only the newest item, so the recap has to stand alone. The feed should keep previous entries.

## Candidate

- Base: `aead5a2c861034c585f638fa9e3338d064372039` on `origin/main`.
- [CI on that base](https://github.com/moona3k/macparakeet/actions/runs/38211798735): tests, Swift 6, and release/bundle checks passed.
- This preparation commit bumps the bundled CLI from 5.0.0 to 5.1.0 and adds these notes. Fill in the signed commit, build number, DMG size, and SHA-256 at publication. Do not copy the 0.8.9 artifact identity forward.

## Still open before or after the tag

- [#1228](https://github.com/moona3k/macparakeet/issues/1228) is not in this candidate. Unattributed system-track words can still appear as an extra “Others” speaker, and keeping one-word turns makes those leftovers more visible. If that fix lands before the tag, add it to `github.md` and `sparkle.html`.
- [#1199](https://github.com/moona3k/macparakeet/issues/1199) is the 16 GB M2 Air / Teams memory report. The cleaned-mic renderer is bounded in this candidate. That measurement does not close the Air report. Release notes describe the footprint drop and do not say the freeze is fixed.
- [#920](https://github.com/moona3k/macparakeet/issues/920), [#912](https://github.com/moona3k/macparakeet/issues/912), and [#1214](https://github.com/moona3k/macparakeet/issues/1214) remain open and are already true of 0.8.9.

## Gates

Voice Control, cross-recording Ask, voice profiles, encrypted share links, and in-process MLX stay off in release builds. **0.9.0** stays reserved for qualified Voice Control.

The app and CLI both default Anthropic to `claude-sonnet-5-5` and OpenRouter to `anthropic/claude-sonnet-5.5`. New Summary prompts include meeting notes in both surfaces; existing libraries keep their saved preference. Meeting URL controls default off in the app and are not a CLI command.

## Not yet verified

Signed app and DMG notarization, stapling, Gatekeeper, the mounted CLI version, a Sparkle upgrade, website changelog deployment, and physical microphone, Bluetooth, or 16 GB capture. Those belong to the publication steps in [distribution](../../distribution.md).
