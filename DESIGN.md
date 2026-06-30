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
  folder-card:
    backgroundColor: "{colors.tactical-card}"
    textColor: "{colors.tactical-foreground}"
    rounded: "{rounded.panel}"
    size: "232px x 64px"
---

# Design System: Icarus

## 1. Overview

**Creative North Star: "The Tactical Workbench"**

Icarus should feel like a disciplined workbench for planning Valorant rounds: dark, compact, map-first, and deliberate. The UI is allowed to be dense because the work is dense, but every cluster needs an obvious job and a stable place. Panels, toolbars, filter controls, and strategy cards should support tactical thinking without asking for attention.

The current system is a dark Shad UI foundation with a restrained violet accent, cool zinc surfaces, image-rich map and agent assets, and small, fast transitions. The product direction is minimal, intuitive, tasteful, and fast; polish comes from order, not ornament.

This system explicitly rejects disorganized layouts, flashy color, novelty effects, cluttered panels, and features that look shoehorned into the interface. If a control cannot explain why it sits where it sits, it is not refined enough.

**Key Characteristics:**
- Canvas-first: map, agents, abilities, drawings, and lineups stay visually dominant.
- Restrained tactical color: violet marks primary action and selection only.
- Dense but calm: tool surfaces are compact, predictable, and grouped by task.
- Native product typography: system sans, practical weights, no decorative type.
- Fast state feedback: transitions are short and communicate hover, selection, reveal, or loading.

## 2. Colors

The palette is a restrained tactical dark system: near-black workspace surfaces, zinc panels, one violet action accent, and semantic colors reserved for tactical meaning.

### Primary
- **Command Violet**: The primary action and selection color. Use it for current tool state, primary buttons, active segmented tabs, focus rings, and success toasts. It should remain rare enough that it keeps command value.
- **Deep Selection Violet**: The deeper selected-region color. Use it for selection backgrounds or lower-emphasis active areas, never as a decorative gradient.

### Secondary
- **Ally Green**: Tactical ally marker color. Use for player-side identity and team state, not general positive UI.
- **Enemy Red**: Tactical enemy marker color. Use for opponent identity and destructive warnings only when context makes the distinction clear.
- **Favorite Amber**: Favorite state and favorites-only filter indicator. Use sparingly; it is a utility state, not a brand accent.

### Tertiary
- **Map Ember Base**: The warm base hue used by map recoloring.
- **Map Callout Bronze**: The warm detail hue used for map geometry and callout texture.
- **Map Highlight Orange**: The map highlight hue used for tactically relevant map contrast.

### Neutral
- **Workbench Black**: App background and deepest canvas environment.
- **Sidebar Charcoal**: Legacy sidebar, menu, and dialog foundation.
- **Panel Zinc**: Primary card, popover, and sidebar panel surface.
- **Raised Zinc**: Secondary, muted, input, border, and hover surface.
- **Muted Text Zinc**: Secondary labels, helper text, inactive controls, and compact metadata.
- **Tactical White**: Foreground and high-contrast text.

### Named Rules

**The One Command Color Rule.** Violet is for current action, selection, focus, and primary commands. It is not decoration.

**The Tactical Semantics Rule.** Ally, enemy, favorite, and map colors carry game meaning. Do not reuse them for unrelated UI emphasis.

## 3. Typography

**Display Font:** System UI sans stack.
**Body Font:** System UI sans stack.
**Label/Mono Font:** System UI sans stack.

**Character:** Typography should feel native, quiet, and utilitarian. Scale and weight do the hierarchy work; the app does not need a decorative display face.

### Hierarchy
- **Display**: Not a standard Icarus role. Avoid hero-scale type inside the product.
- **Headline** (500, 20px, 1.2): Section headings such as Tools and Agents.
- **Title** (600, 16px, 1.25): Dialog titles, settings group titles, compact card titles, and primary row labels.
- **Body** (400, 14px, 1.35): Normal controls, option labels, strategy metadata, and helper text.
- **Label** (600, 12px, 0.3px letter spacing): Section labels, filter state text, compact state descriptions, and setting captions.
- **Micro** (600, 9-10px, 0.5-0.8px letter spacing): Badges such as DEFAULT and CUSTOM OVERRIDE.

### Named Rules

**The Native Tool Rule.** Use the system sans stack for all product UI. Display fonts, novelty fonts, and over-styled labels are forbidden.

**The Compact Legibility Rule.** Dense panels may use small text, but labels must keep enough weight, contrast, and spacing to scan at desktop distance.

## 4. Elevation

Icarus is flat by default and uses tonal layering first: background, panel, raised control, border, and selected state. Shadows are reserved for foregrounded content like strategy tile detail panels, drag previews, folder drag cards, delete menus, and popover-like controls. Depth should clarify stacking or interaction, never decorate an otherwise flat surface.

### Shadow Vocabulary
- **Card Foreground Backdrop** (`0 4px 12px rgba(0,0,0,0.54)`): Used on card foreground details and select controls to separate them from dark textured surroundings.
- **Folder Drag Lift** (`0 4px 12px rgba(0,0,0,0.54)`): Used only on draggable folder card previews to separate them from the dotted canvas.
- **Delete Menu Lift** (`0 8px 24px rgba(0,0,0,0.28)`): Used on floating destructive-control panels.

### Named Rules

**The Tonal First Rule.** Prefer surface changes and borders before shadows. If a shadow does not explain stacking, remove it.

## 5. Components

### Buttons

Buttons are compact, icon-led, and stateful. Primary buttons use Command Violet for decisive actions such as Create Strategy or Save, secondary buttons use Raised Zinc for utility actions, and ghost icon buttons stay transparent over the canvas.

- **Shape:** Soft product corners (8px) for standard buttons; compact icon buttons inherit the same control language.
- **Primary:** Command Violet background, Tactical White text, icon-leading when the action has a familiar symbol.
- **Hover / Focus:** Hover uses the Shad state layer; focus uses the violet ring. Keep transitions around 150-250ms.
- **Secondary / Ghost:** Secondary buttons sit on Raised Zinc. Ghost buttons are reserved for canvas chrome and toolbar actions where a filled button would compete with the map.

### Chips

Chips are functional state markers, not decoration. Folder cards may show user-authored color, but color lives inside the icon swatch rather than flooding the entire surface; state badges use tinted violet surfaces and small uppercase type.

- **Style:** Folder cards are 232px wide, 64px tall, 12px radius, zinc surface, 1px zinc border, a 40px tinted icon swatch, title text, muted metadata, and a compact menu button.
- **State:** Hover changes the border to Command Violet without scaling. Drop-target state uses a 2px Command Violet border and faint violet surface tint.

### Cards / Containers

Cards and panels are used for actual grouped tools or repeated objects, not as generic section wrappers.

- **Corner Style:** Sidebar panels use 12px radius. Strategy tiles and thumbnails use 16px radius. Dialogs use 22px radius.
- **Background:** Panel Zinc for cards and sidebars; Raised Zinc for controls within panels.
- **Shadow Strategy:** Flat at rest except foreground card detail blocks and floating controls.
- **Border:** 1-2px zinc borders define edges in dark space. Avoid colored side-stripe borders.
- **Internal Padding:** Tool panels use 16px grouping; settings sheets use 24px outer padding; cards use 8-16px.

### Inputs / Fields

Inputs are dark, bordered, and compact. Search is a signature interaction: it collapses to an icon at rest and expands on hover, focus, or text entry.

- **Style:** Panel Zinc fill, 8px radius, 1px zinc border.
- **Focus:** Command Violet cursor and 2px ring/border.
- **Error / Disabled:** Use destructive red for true errors only; disabled controls stay muted rather than saturated.

### Navigation

Navigation is practical and spatial. The library uses a top app bar with breadcrumbs and action buttons; the strategy editor uses a compact top strip plus canvas overlays for map selection, settings, save, export, screenshots, pages, and the right-side tool panel.

- **Style:** Keep navigation predictable: top row for global context, right panel for creation tools, left/overlay controls for strategy-level actions.
- **Motion:** Route changes use 200ms fade/scale transitions. Reveals use 150-250ms easing and must communicate state.

### Signature Component

The strategy editor right sidebar is the signature product component. It combines a tool grid, contextual tool bar, filters, team selection, role filters, draggable agent tiles, and an ability rail. Its job is to keep strategy creation fast without cluttering the map.

## 6. Do's and Don'ts

### Do:

- **Do** keep the map and tactical objects visually dominant; supporting UI should feel like workbench hardware around the canvas.
- **Do** use Command Violet for selected tools, primary actions, focus rings, and current assignments.
- **Do** group tools by task and reveal contextual controls only when the current interaction mode needs them.
- **Do** keep dense panels orderly with consistent 8px, 10px, 12px, 16px, and 24px spacing steps.
- **Do** use icons for familiar tool actions, with tooltips for compact controls.
- **Do** preserve tactical color meaning for ally, enemy, favorite, destructive, and map states.
- **Do** keep transitions short: 150-250ms for hover, reveal, route, and state changes.

### Don't:

- **Don't** make Icarus look disorganized, noisy, or arbitrary.
- **Don't** add flashy colors, loud gradients, glow-heavy treatments, glassmorphism, or decorative effects.
- **Don't** shoehorn features into spare space; every control needs a clear reason for its position.
- **Don't** reuse ally, enemy, favorite, or map colors for unrelated UI decoration.
- **Don't** introduce marketing-page composition, hero typography, decorative dashboards, or generic gamer overlay styling.
- **Don't** use colored side-stripe borders, gradient text, nested cards, or identical decorative card grids.
- **Don't** invent custom affordances where standard Shad, Flutter, or desktop patterns already communicate the action clearly.
