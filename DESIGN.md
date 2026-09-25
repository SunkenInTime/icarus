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

## Window chrome

- Desktop builds hide the native title bar. Each top-level screen draws its own 40px strip (`lib/widgets/window_chrome.dart`): macOS keeps its traffic lights, so the strip leaves a 78px inset on the left; Windows and Linux get app-drawn caption buttons on the right; the strip is the drag handle. Web renders the same strip with no inset and no buttons.
- An update icon exists only while an update is waiting, drawn by `AppWindowStrip` itself just before the caption buttons (`lib/widgets/strip_status_icons.dart`), so it shows on every screen and no screen places it.
- The library strip holds the three tabs on the left and only What's new (past patch notes), search, sort, New, and the account on the right. Nothing else goes in it. Inside a folder, the breadcrumb lives in the content area, not the strip.
- The app version lives at the foot of the settings navigation rail, muted; click copies it. It is not in any strip.
- The editor's document actions (save, export, video, screenshot, settings) sit in one card at the top-left of the canvas (`lib/widgets/editor_toolbar.dart`). For a cloud strategy the save button's glyph is the sync state; the words live in its tooltip and a popover opens only when sync needs attention. No status chips or labels in the editor.

## Icons

- Lucide is the icon family (`LucideIcons.*`, re-exported by shadcn_ui). Material `Icons.*` only survive in the persisted folder-icon registry and cursor glyphs. Toolbar and tool glyphs are 18-22px, menu and inline glyphs 16px.
- Icons rest in muted foreground and come up to foreground on hover. Violet on an icon means it is the selected or checked item, nothing else.

## Things I would like to remain consistent

**The One Command Color** Violet marks current action, selection, focus, and primary commands, and nothing else. If violet appears somewhere that isn't actionable or active, it's wrong.

**The Tactical Semantics** Ally green, enemy red, defender blue, favorite amber, and the map ember hues carry game meaning. Never reuse them for unrelated UI emphasis.

**The Tonal First** Depth comes from surface steps (background, panel, raised) and 1px zinc borders. A shadow is only allowed where it explains stacking: drag previews, floating menus, card foreground details (`0 4px 12px rgba(0,0,0,0.54)` / `0 8px 24px rgba(0,0,0,0.28)`). A selected or primary state is never a flat fill: it is a raised surface, lit from above. The fill runs lighter at the top, a 1px light sits inside the top edge, a 1px shade inside the bottom, and a 1px shadow drops beneath; the sides stay bare. `Settings.raised(color, radius)` builds it for any base color (`raisedPrimary` and `raisedSurface` are the violet and zinc shortcuts), painted by `InsetShadowDecoration` (`lib/widgets/inset_shadow_decoration.dart`), which also tweens in animated containers. Primary buttons get it from the Shad theme. Hover stays flat.

**Every control earns its position.** If you can't say why a control sits where it sits, it isn't done. Never fill spare space with a feature.

## Some general rules
These steer us in the right direction. They are not hard-set, but default to following them; if you think one should be ignored, be very loud about it and get approval from us first.
