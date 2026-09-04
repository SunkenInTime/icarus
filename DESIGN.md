# Design: Icarus

Icarus is a tactical workbench: dark, dense, map-first. The canvas and the tactical objects on it stay visually dominant; everything else is hardware around the bench. Polish comes from order, not ornament.

The palette, theme, and sizing constants live in `lib/const/settings.dart`, with `Settings.tacticalVioletTheme` as the ShadColorScheme. That file is the only source of truth for values. This file holds the rules for using them.

## Building UI

- shadcn_ui is the component library. Reach for `Shad*` widgets first (`ShadDialog`, `ShadButton`, `ShadIconButton`, `ShadInput`, `ShadSelect`, `ShadTooltip`, `ShadContextMenu*`, `ShadPopover`) before Material equivalents or custom widgets. Read theme values through `ShadTheme.of(context)`.
- `ShadDialog` does not provide a `Material` ancestor. Material-dependent children (`TextField`, `InkWell`, `LinearProgressIndicator`, `Slider`) throw "No Material widget found" inside one. Wrap the dialog's `child` in `Material(color: Colors.transparent, child: ...)`; see `lib/widgets/dialogs/export_video_dialog.dart` for the idiom.
- Never hardcode a hex that already has a name in `lib/const/settings.dart`. If a color is new, name it there first.
- Spacing steps are 8/10/12/16/24px. Radii: 8px controls, 12px panels, 16px cards, 22px dialogs.
- Type roles, all in the system sans stack: headline 20px/500, title 16px/600, body 14px/400, label 12px/600, micro 10px/600. Hierarchy comes from these five roles, not from display fonts or hero-scale type.
- Transitions run 150-250ms and must communicate a state change (hover, selection, reveal, loading). No motion for its own sake.

## Named rules

**The One Command Color Rule.** Violet marks current action, selection, focus, and primary commands, and nothing else. If violet appears somewhere that isn't actionable or active, it's wrong.

**The Tactical Semantics Rule.** Ally green, enemy red, defender blue, favorite amber, and the map ember hues carry game meaning. Never reuse them for unrelated UI emphasis.

**The Tonal First Rule.** Depth comes from surface steps (background, panel, raised) and 1px zinc borders. A shadow is only allowed where it explains stacking: drag previews, floating menus, card foreground details (`0 4px 12px rgba(0,0,0,0.54)` / `0 8px 24px rgba(0,0,0,0.28)`).

**Every control earns its position.** If you can't say why a control sits where it sits, it isn't done. Never fill spare space with a feature.

## Don't

- No gradients, glow, glassmorphism, or decorative effects on chrome. The anti-reference is the generic gamer overlay. Gradients and blur that do a job on the canvas are fine and intentional: the map vignette, the loading skeleton shimmer, the color picker, the view cone falloff, and the media carousel backdrop.
- No marketing-page composition inside the product: no hero typography, no decorative dashboards.
- No colored side-stripe borders, gradient text, or nested cards.
- No custom affordance where a standard Shad or desktop pattern already communicates the action.
