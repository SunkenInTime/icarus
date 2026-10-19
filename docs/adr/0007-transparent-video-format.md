# ADR 0007: Transparent video exports as QuickTime Animation .mov

**Status:** Accepted (2026-10-18)
**Feature:** Video export with a transparent background

## Context

Users asked to export a strategy video with the background left out, to lay
it over their own footage. H.264 MP4 has no alpha channel, so a transparent
video needs another format. No format keeps alpha everywhere, so on
2026-10-18 the same 20-second clip was exported three ways and composited over
green in the editors on hand:

| Format | DaVinci Resolve 21.0.2 | Clipchamp | Edge | Size |
| --- | --- | --- | --- | --- |
| VP9 WebM | Alpha kept, but half-transparent pixels drawn solid | Correct | Correct | 0.5 MB |
| ProRes 4444 .mov | Correct | Map nearly invisible | Won't play | 355 MB |
| QuickTime Animation .mov | Correct | Correct | Won't play | 3 MB (keyframe every 2 s) |

Half-transparent pixels matter here: utility areas are drawn translucent, and
transitions fade items in and out. The web build has no ffmpeg, and its
WebCodecs encoder refuses to keep alpha for any codec.

## Decision

1. A transparent export is a QuickTime Animation (`rle `, 32-bit ARGB) .mov:
   lossless, 1920×1080, 30 fps, keyframe every 2 seconds and on the last
   frame.
2. It is encoded in Dart (`QuickTimeAnimationEncoder`, `MovAnimationMuxer`),
   so desktop and web produce the same file without ffmpeg or WebCodecs.
3. The Potato, Social and Max presets don't apply; the dialog dims them while
   Transparent background is ticked. The choice is remembered in app
   preferences.

## Consequences

- Correct in both editors tested. Browsers and simple players can't play the
  file; it is meant for editors.
- Clipchamp ends a QuickTime Animation clip at its last keyframe, so the
  encoder keys the final frame.
- Frames are read back with straight alpha (`rawStraightRgba`). Premultiplied
  colour would darken every half-transparent pixel.
- Premiere Pro, After Effects and CapCut were not tested.
