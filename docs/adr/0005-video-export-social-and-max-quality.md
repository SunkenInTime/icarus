# ADR 0005: Video export offers Social and Max quality presets

**Status:** Accepted (2026-08-15)
**Feature:** Video export (pages → .mp4)

## Context

ADR 0003 fixed video export at 1920×1080, 60 fps, and one encoder quality.
That keeps the settings dialog small, but output size follows strategy duration:
the Windows H.264 path always requests 8 Mbps and the MPEG-4 fallback targets
quality rather than bytes. A non-Nitro Discord user may be limited to a 10 MiB
attachment, so a long strategy can export successfully but still fail at the
moment it is shared.

A raw bitrate setting would make users calculate file size from video duration.
H.265 can compress more efficiently, but its Media Foundation encoder and
playback support vary by Windows installation. H.264 remains the compatible
MP4 default.

## Decision

1. The dialog exposes one **Quality** setting with two presets:
   - **Social** — 1920×1080, 30 fps, H.264, finished file at or below 10 MiB.
   - **Max** — 1920×1080, 60 fps, the existing highest-quality behavior.
2. Social is selected whenever the dialog opens. The choice is export-only and
   is not added to the Hive-backed app preferences.
3. Social calculates its first video bitrate from planned duration and a
   9.25 MiB working target, reserving 64 kbps for mux and encoder overhead. It
   caps short videos at the existing 8 Mbps request and refuses durations that
   would require less than 250 kbps.
4. Social renders page transitions at 30 fps rather than rendering at 60 fps
   and dropping half the images during encoding. Max retains 60 fps.
5. Social writes to the existing partial path and measures the finished bytes
   before replacing the destination. An oversized result gets one
   proportionally lower-bitrate retry; a second oversize result fails without
   saving.
6. Social does not fall back to MPEG-4 Part 2 when H.264 fails because the
   quality-targeted fallback cannot uphold the file-size promise. Max retains
   the fallback.
7. Codec and bitrate are implementation details, not user-facing controls.

All other decisions from ADR 0003 remain: one global step duration, arbitrary
page inclusion in strategy order, the existing save flow, and cancellable
progress.

## Consequences

- A user can choose the outcome they need without knowing codecs or bitrate
  arithmetic.
- Social handles a 30-page strategy at the default 3-second step duration at
  roughly 693 kbps while retaining 1080p detail.
- Social renders 407 images for that 30-page export instead of Max's 755, a
  46.1% reduction in the dominant rendering phase.
- Very long exports can be rejected as unreadable under 10 MiB. The dialog
  explains how to shorten them before opening the save picker.
- H.265 remains a possible future compatibility-limited preset, not a hidden
  dependency of the reliable sharing path.
