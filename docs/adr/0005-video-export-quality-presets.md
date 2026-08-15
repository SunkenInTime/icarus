# ADR 0005: Video export offers Potato, Social, and Max quality presets

**Status:** Accepted (2026-08-15)
**Feature:** Video export (pages → .mp4)

## Context

ADR 0003 fixed video export at 1920×1080, 60 fps, and one encoder quality.
That keeps the settings dialog small, but output size follows strategy duration:
the Windows H.264 path always requests 8 Mbps and the MPEG-4 fallback targets
quality rather than bytes. Discord attachment limits vary by account and
server, and Discord is experimenting with larger limits. Treating one current
limit as a hard export gate would make a changing external policy prevent the
user from finishing their work.

A raw bitrate setting would make users calculate file size from video duration.
H.265 can compress more efficiently, but its Media Foundation encoder and
playback support vary by Windows installation. H.264 remains the compatible
MP4 default.

Resolution is not a reliable proxy for a smaller or clearer strategy video.
In a controlled 22-second tactical-motion comparison, 1080p beat 720p at 300
and 450 kbps. At the 250 kbps readable floor, 720p finally scored higher (VMAF
84.163 versus 80.169). Potato therefore keeps 1080p normally and only
downscales extremely long exports whose duration-derived bitrate reaches the
floor. The benchmark is directional because visual metrics are content- and
machine-dependent.

## Decision

1. The dialog exposes one **Quality** setting with three outcome presets:
   - **Potato** — 30 fps, H.264, with a best-effort 10 MiB target. It is
     normally 1920×1080 and adaptively outputs 1280×720 at the bitrate floor.
   - **Social** — 1920×1080, 30 fps, H.264, with a best-effort 20 MiB target.
   - **Max** — 1920×1080, 60 fps, the existing highest-quality behavior.
2. Social is selected whenever the dialog opens. The choice is export-only and
   is not added to the Hive-backed app preferences.
3. Potato and Social calculate their first video bitrate from planned
   duration, reserving 64 kbps for mux and encoder overhead. Potato uses a
   9.25 MiB working target; Social uses 18.5 MiB. Both cap short videos at the
   existing 8 Mbps request and keep long videos at a readable 250 kbps floor.
4. Potato drops the encoded output to 720p only when its initial bitrate is at
   that 250 kbps floor. Icarus still renders the source page at 1080p and
   performs one high-quality Lanczos downscale in FFmpeg, avoiding a second
   coordinate system in the screenshot renderer.
5. Potato and Social render page transitions at 30 fps rather than rendering
   at 60 fps and dropping half the images during encoding. Max retains 60 fps.
6. Size-targeted presets write to the existing partial path and measure the
   finished bytes before replacing the destination. An oversized result gets
   one proportionally lower-bitrate retry when a lower readable bitrate
   remains. After that, the successful result is saved even if it is still over
   target.
7. Size-targeted presets do not fall back to MPEG-4 Part 2 when H.264 fails
   because the quality-targeted fallback cannot follow a bitrate target
   predictably. Max retains the fallback.
8. Codec and bitrate are implementation details, not user-facing controls. The
   Potato description does show 1080p or 720p for the selected duration so
   adaptive resolution is visible rather than surprising.

All other decisions from ADR 0003 remain: one global step duration, arbitrary
page inclusion in strategy order, the existing save flow, and cancellable
progress.

## Consequences

- A user can choose limited uploads, ordinary sharing, or maximum quality
  without knowing codecs or bitrate arithmetic.
- Potato handles a 30-page strategy at the default 3-second step duration at
  roughly 693 kbps while retaining 1080p detail and aiming for 10 MiB.
- Social handles the same strategy at roughly 1.45 Mbps and aims for 20 MiB.
- Potato and Social render 407 images for that 30-page export instead of
  Max's 755, a 46.1% reduction in the dominant rendering phase.
- Size-targeted presets never reject a successfully encoded video based on
  duration or file size. Very long or unusually complex exports may exceed the
  selected target.
- H.265 remains a possible future compatibility-limited preset, not a hidden
  dependency of the reliable sharing paths.
