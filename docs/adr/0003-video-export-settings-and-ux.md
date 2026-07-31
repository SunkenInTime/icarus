# ADR 0003: Video export settings — global step duration, page checkboxes, fixed 1080p

**Status:** Accepted (2026-07-31)
**Feature:** Video sequencing export (pages → .mp4)

## Context

The feature request asks for "settings like step duration and what pages you
want to include". Icarus has no export-settings dialog today: screenshot
resolution is hard-coded to `CoordinateSystem.screenShotSize` (1920×1080) and
all save flows go through `FilePicker.platform.saveFile`. Dialog patterns to
copy live in `lib/widgets/dialogs/` (shadcn `ShadDialog` style). "Steps" and
"pages" are the same concept: `StrategyPage` entries ordered by `sortIndex`.

## Decision

1. **Step duration is a single global setting per export**: how long each
   included page is held on screen. **Default 3 s, clamped to 1–30 s.**
   No per-page overrides in v1.
2. **Page inclusion is an arbitrary subset** chosen via a checkbox list
   (page name + order) in the export dialog, **all checked by default**.
   Order is always `sortIndex` order; transitions run between consecutive
   included pages.
3. **Resolution and quality are fixed in v1**: 1920×1080 (reusing the
   screenshot pipeline unchanged), fixed encoder quality settings. No
   resolution/bitrate knobs.
4. **Entry point**: an "Export Video" action alongside the existing
   Screenshot / Export (.ica) buttons in the strategy view
   (`save_and_load_button.dart`), opening the settings dialog, then a save-as
   dialog for the `.mp4` path.
5. **Persistence**: the last-used step duration persists in Hive app
   settings. Page selection does **not** persist (it is strategy-specific and
   goes stale as pages change) — it resets to all-selected each time.
6. Export runs with a **progress dialog (per-frame / encoding phases) and a
   Cancel button**; cancellation kills the ffmpeg process and deletes temp
   frames. Fires a `content_exported`-style analytics event like existing
   exports.

## Consequences

- The common case is two clicks: Export Video → Save. The dialog stays small
  (checkbox list + one duration control).
- Per-page durations, transition-duration control, and resolution presets are
  deliberate non-goals for v1; the settings model (a
  `VideoExportSettings{pageIds, stepDuration}` value object) leaves room for
  them.
- Fixing 1080p means zero new coordinate-system code paths — the
  `ScreenshotView` pipeline is reused as-is.
