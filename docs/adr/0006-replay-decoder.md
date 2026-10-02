# 6. Valorant replays are decoded by a native library built on vrfkit

Status: accepted, 2026-10-01

## Context

Valorant writes match replays as `.vrf` files: an Unreal local replay, its
replication payloads Oodle-compressed and scrambled by a transform Riot
rotates every patch or two. We spent June and July reverse engineering the
format in Node (`codex/valorant-replay-file-reverse-engineering`). That work
proved the layers and decoded movement for build 13.00, but it ran 30 to 300
seconds per match, knew three builds, and shelled out to Node, which no user
has installed.

Since then two open-source parsers have caught up and track every patch:
vrfkit (Rust, Apache-2.0, builds 11.06 to 13.06) and Michel Giehl's
ValorantReplayParser (C#, MIT, which vrfkit derives from). vrfkit decodes one
of our 13.00 replays in about a second with no decode errors.

Every open-source Oodle decoder (powzix/ooz and its ports: ooz-wasm,
oozextract, OozSharp, oozle) is GPL-3.0 or derived from it, including the ones
labelled MIT. Valorant only uses a narrow Oodle subset: Mermaid/Selkie blocks
with raw, un-entropy-coded streams.

## Decision

- `native/replay` is a Rust library, loaded over FFI like `native/height`.
  It depends on vrfkit's library crates pinned to a release tag, with the
  `oodle` feature off, and vendors the CLI's packet pass with attribution.
- Its Oodle decoder is our own, written clean-room for the Selkie subset from
  a facts-only format spec. ooz-derived code never enters the repo or the
  build. Any block outside the subset fails loudly.
- The library emits Valorant facts only (subjects, agent UUIDs, class paths,
  game-world centimetres) in the format described in
  [`docs/replay-format.md`](../replay-format.md). Mapping those facts onto
  Icarus agents, abilities and map coordinates is Dart's job, so the decoded
  document stays readable by code that has never seen our widgets.
- A replay from an unknown build is refused, never guessed. Keeping up with
  patches means bumping the vrfkit tag.

## Consequences

- Building the desktop app needs a Rust toolchain on Windows and macOS.
  Unit tests that do not touch decoding stay pure Dart.
- New Valorant patches reach users when vrfkit registers the build and we
  ship a release with the bumped tag. Until then that patch's replays show a
  clear "not supported yet" state.
- The same crate can compile to WASM if the web app ever decodes replays.
