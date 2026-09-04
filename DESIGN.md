---
name: Icarus
description: A refined tactical desktop workspace for Valorant strategy planning.
colors:
  tactical-background: "#09090b"
  tactical-sidebar: "#141114"
  tactical-card: "#18181b"
  tactical-panel: "#1b1b1b"
  tactical-raised: "#27272a"
  tactical-border: "#27272a"
  tactical-scrollbar: "#353435"
  tactical-foreground: "#fafafa"
  tactical-muted: "#a1a1aa"
  tactical-primary: "#7c3aed"
  tactical-primary-deep: "#4c1d95"
  tactical-primary-foreground: "#f9fafb"
  tactical-danger: "#ef4444"
  tactical-favorite: "#ff9800"
  tactical-favorite-danger: "#e53935"
  tactical-ally: "#3a7e5d"
  tactical-ally-outline: "#69f0af6a"
  tactical-enemy: "#772727"
  tactical-enemy-outline: "#ff52528b"
  map-base: "#271406"
  map-detail: "#b27c40"
  map-highlight: "#f08234"
typography:
  headline:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "20px"
    fontWeight: 500
    lineHeight: 1.2
    letterSpacing: "normal"
  title:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "normal"
  body:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.35
    letterSpacing: "normal"
  label:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.3px"
  micro:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, sans-serif"
    fontSize: "10px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.5px"
rounded:
  xs: "3px"
  sm: "4px"
  md: "6px"
  lg: "8px"
  xl: "10px"
  panel: "12px"
  card: "16px"
  dialog: "22px"
  pill: "22px"
spacing:
  xxs: "2px"
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "10px"
  xl: "12px"
  section: "16px"
  panel: "24px"
  grid-gap: "20px"
components:
  button-primary:
    backgroundColor: "{colors.tactical-primary}"
    textColor: "{colors.tactical-primary-foreground}"
    rounded: "{rounded.lg}"
    padding: "8px 14px"
  button-secondary:
    backgroundColor: "{colors.tactical-raised}"
    textColor: "{colors.tactical-foreground}"
    rounded: "{rounded.lg}"
    padding: "8px 14px"
  icon-button:
    backgroundColor: "{colors.tactical-raised}"
    textColor: "{colors.tactical-foreground}"
    rounded: "{rounded.lg}"
    size: "40px"
  tool-button-selected:
    backgroundColor: "{colors.tactical-primary}"
    textColor: "{colors.tactical-primary-foreground}"
    rounded: "{rounded.lg}"
    size: "57.8px"
  search-field:
    backgroundColor: "{colors.tactical-card}"
    textColor: "{colors.tactical-foreground}"
    rounded: "{rounded.lg}"
    height: "40px"
  segmented-tabs:
    backgroundColor: "{colors.tactical-raised}"
    textColor: "{colors.tactical-muted}"
    rounded: "{rounded.md}"
    padding: "2px"
  strategy-card:
    backgroundColor: "{colors.tactical-card}"
    textColor: "{colors.tactical-foreground}"
    rounded: "{rounded.card}"
    padding: "8px"
  sidebar-panel:
    backgroundColor: "{colors.tactical-card}"
    textColor: "{colors.tactical-foreground}"
    rounded: "{rounded.panel}"
    width: "345px"
  title-strip:
    backgroundColor: "{colors.tactical-card}"
    textColor: "{colors.tactical-foreground}"
    height: "40px"
    controlHeight: "28px"
  folder-card:
    backgroundColor: "{colors.tactical-card}"
    textColor: "{colors.tactical-foreground}"
    rounded: "{rounded.panel}"
    size: "232px x 64px"
---

# Design: Icarus

Icarus is a tactical workbench: dark, dense, map-first. The canvas and the tactical objects on it stay visually dominant; everything else is hardware around the bench. Polish comes from order, not ornament.

## Building UI

- shadcn_ui is the component library. Reach for `Shad*` widgets first — `ShadDialog`, `ShadButton`, `ShadIconButton`, `ShadInput`, `ShadSelect`, `ShadTooltip`, `ShadContextMenu*`, `ShadPopover` — before Material equivalents or custom widgets. Read theme values through `ShadTheme.of(context)`.
- `ShadDialog` does not provide a `Material` ancestor. Material-dependent children (`TextField`, `InkWell`, `LinearProgressIndicator`, `Slider`) throw "No Material widget found" inside one. Wrap the dialog's `child` in `Material(color: Colors.transparent, child: ...)` — see `lib/widgets/dialogs/export_video_dialog.dart` for the idiom.
- Color, theme, and sizing constants live in `lib/const/settings.dart` (including the `tacticalVioletTheme` ShadColorScheme). Use them; never hardcode a hex that already has a name. The frontmatter above mirrors these values for reference.
- Spacing uses the 8/10/12/16/24px steps from the frontmatter. Radii: 8px controls, 12px panels, 16px cards, 22px dialogs.
- Transitions run 150-250ms and must communicate a state change (hover, selection, reveal, loading). No motion for its own sake.

## Window chrome

- Desktop builds hide the native title bar. Each top-level screen draws its own 40px strip (`lib/widgets/window_chrome.dart`): macOS keeps its traffic lights, so the strip leaves a 78px inset on the left; Windows and Linux get app-drawn caption buttons on the right; the strip is the drag handle. Web renders the same strip with no inset and no buttons.
- The library strip holds the three tabs on the left and only search, sort, New, and the account on the right. Nothing else goes in it. Inside a folder, the breadcrumb lives in the content area, not the strip.

## Named rules

**The One Command Color Rule.** Violet marks current action, selection, focus, and primary commands — nothing else. If violet appears somewhere that isn't actionable or active, it's wrong.

**The Tactical Semantics Rule.** Ally green, enemy red, favorite amber, and the map ember hues carry game meaning. Never reuse them for unrelated UI emphasis.

**The Tonal First Rule.** Depth comes from surface steps (background → panel → raised) and 1px zinc borders. A shadow is only allowed where it explains stacking: drag previews, floating menus, card foreground details (`0 4px 12px rgba(0,0,0,0.54)` / `0 8px 24px rgba(0,0,0,0.28)`).

**The Native Tool Rule.** System sans stack for everything. Hierarchy comes from the five frontmatter type roles (headline/title/body/label/micro), not from display fonts or hero-scale type.

**Every control earns its position.** If you can't say why a control sits where it sits, it isn't done. Never fill spare space with a feature.

## Don't

- No gradients, glow, glassmorphism, or decorative effects — the anti-reference is the generic gamer overlay.
- No marketing-page composition inside the product: no hero typography, no decorative dashboards.
- No colored side-stripe borders, gradient text, or nested cards.
- No custom affordance where a standard Shad or desktop pattern already communicates the action.
