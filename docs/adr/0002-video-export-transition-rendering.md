# ADR 0002: Video transitions reuse the in-app page-transition system at full fidelity

**Status:** Amended by ADR 0005 (2026-08-15)
**Feature:** Video sequencing export (pages → .mp4)

## Context

Page changes in the exported video could be hard cuts, crossfades, or the
animated transition users see in the editor. The in-app system
(`TransitionProvider`, `PageTransitionOverlay`) is a full diffing engine:

- Widgets present on both pages get `TransitionKind.move` entries with lerped
  position (optionally along a curved `AgentTransitionPath`), rotation,
  ability arm lengths, text size, scale, custom dimensions, and dead-state
  blending.
- Widgets on only one page get `appear`/`disappear` entries with opacity
  fades plus a small directional slide.
- Rendering is a **pure function of progress `t`** — `_buildEntry` and
  `PlacedWidgetPreview.build` need no live animation, only state + `t`.
- The entry diffing lives in `StrategyProvider`'s page-switch logic; the
  overlay applies `Curves.easeOutCubic` and `kPageTransitionDuration`
  (420 ms).

Frame capture already exists: `ScreenshotView` renders one page statelessly
offscreen at 1920×1080 via `ScreenshotController.captureFromWidget`.

## Decision

1. **Full in-app parity**: exported transitions must look like the editor's
   page switch — curved agent paths, ability morphs, appear/disappear fades,
   dead-state blends.
2. **Timing matches the app exactly: 420 ms per transition, sampled at
   60 fps** (~25 interpolated frames per page change), using the same
   `Curves.easeOutCubic`.
3. Implementation approach: extract the entry-diffing from the page-switch
   logic into a shared function `computeTransitionEntries(fromPage, toPage)`,
   and extract the overlay's `t`-parameterized rendering into a widget usable
   offscreen (`TransitionFrameView(entries, agentPaths, t, ...)`) composed
   over the same base layers `ScreenshotView` uses. The live overlay and the
   exporter both consume these shared pieces — no forked rendering logic.
4. Transitions are computed pairwise between **consecutive included pages**
   (see ADR 0003), so excluding a middle page transitions directly across it.
5. **Freehand drawings and images fade in early** during a transition
   (front-loaded — completing in roughly the first half of the 420 ms, exact
   window tuned by eye during implementation). Today drawings are not
   `PlacedWidget`s and produce no transition entries; this adds that behavior
   to the **in-app transition system first**, and the exported video inherits
   it through parity. (This was a long-considered in-app improvement, decided
   here as part of the video-export design.)

## Consequences

- Highest-quality output and zero visual drift between editor and video, at
  the cost of a refactor: `PageTransitionOverlay` currently reads live
  providers and the `CoordinateSystem.instance` singleton and must be split
  into pure-render vs. animation-driving parts.
- Frame budget stays small: N pages ≈ N still holds + (N−1) × ~25 transition
  frames. Holds are encoded from a single still with duration metadata, not
  re-rendered per frame.
- The drawing/image fade-in (point 5) widens scope beyond export: it touches
  the live transition pipeline (`InteractivePainter` layer visibility during
  transitions) and should be built and reviewed in-app before the exporter
  consumes it.
