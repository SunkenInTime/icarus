# Investigation: why design settings don't propagate to existing strategies

**Status:** investigation only, no behavior changes.
**Symptom reported by users:** changing agent size (and some colors) in settings only affects new strategies; old strategies keep their old look and must be edited one by one.

## TL;DR

Agent size, ability size, and the neutral-team-colors toggle are **per-strategy data, not global settings**. They live in a `StrategySettings` object that is stored inside every `StrategyPage` and saved into the Hive `strategies` box with the strategy itself. The sliders in the *global* settings tab do not edit any live setting — they edit `AppPreferences.defaultAgentSizeForNewStrategies` etc., which is read exactly once, at strategy creation time, to seed the new strategy's copy. Nothing ever walks existing strategies to update their stored copies, so old strats never change. This is by design (the settings UI even labels the section "New strategy defaults"), but the distinction is easy to miss.

## The two settings scopes

### 1. Per-strategy (frozen copies): agent size, ability size, neutral team colors

- Model: `StrategySettings { agentSize, abilitySize, useNeutralTeamColors }` — `lib/providers/strategy_settings_provider.dart:10-19`. Defaults come from constants `Settings.agentSize = 35` / `Settings.abilitySize = 25` (`lib/const/settings.dart:40-46`).
- Storage: every page of a strategy carries its own copy — `StrategyPage.settings` (`lib/providers/strategy_page.dart:31`); `StrategyData` also still carries a deprecated top-level `strategySettings` (`lib/providers/strategy_provider.dart:82`). All of it is persisted as part of the strategy in the Hive `strategies` box, and serialized into `.ica` files as `settingsData` (import path: `lib/providers/strategy_provider.dart:2936-2945`).
- The "bake-in" moment: `createNewStrategy` snapshots the app-preference defaults into the new strategy's `StrategySettings` — `lib/providers/strategy_provider.dart:3051-3090`, specifically:
  - `agentSize: appPreferences.defaultAgentSizeForNewStrategies` (`:3058`)
  - `abilitySize: appPreferences.defaultAbilitySizeForNewStrategies` (`:3059`)
  - `useNeutralTeamColors: appPreferences.defaultNeutralTeamColorsForNewStrategies` (`:3060-3061`)

  This is the **only** place the global defaults touch strategy data.
- At load, the opened page's stored copy is pushed into the runtime `strategySettingsProvider` (`lib/providers/strategy_provider.dart:1252` for strategy open, `:912` for page switch). Widgets render from that runtime provider, e.g. `agentSize = ref.watch(strategySettingsProvider).agentSize` in `lib/widgets/draggable_widgets/agents/agent_widget.dart:103-106`.
- At save, the runtime provider is written back into the active page: `settings: ref.read(strategySettingsProvider)` in `_syncCurrentPageToHive` (`lib/providers/strategy_provider.dart:3670`).

So the flow is: **global default → copied once into the strategy at creation → round-tripped between Hive and the runtime provider forever after.** Changing the global default later changes nothing already created; changing the per-strategy sliders (settings tab, "Strategy object styling" section, `lib/widgets/settings_tab.dart:283-337`) changes only the open strategy (and, for the size sliders, only the active page unless the user hits the multi-page sync affordance — see below).

### 2. Global-live settings (these DO apply everywhere immediately)

`AppPreferences` values that are read live via `appPreferencesProvider` apply to every strategy the moment they change: `showSpawnBarrier`, `showUltOrbs`, `showRegionNames`, autosave, Discord presence, drawing defaults, shortcuts, etc. (`lib/providers/user_preferences_provider.dart:112-131`).

Map theme colors are a hybrid:

- A strategy stores a **reference** (`themeProfileId`) to a `MapThemeProfile`, plus an optional frozen `themeOverridePalette` (`lib/providers/strategy_provider.dart:90-91`).
- The palette is resolved at render time by `effectiveMapThemePaletteProvider` (`lib/providers/user_preferences_provider.dart:264-283`), so **editing a custom profile's colors retroactively updates every strategy that references that profile** — reference semantics, live.
- But the "default profile for new strategies" preference (`AppPreferences.defaultThemeProfileIdForNewStrategies`) is again only consumed at `createNewStrategy` (`:3054-3055`, `:3089`), and a per-strategy override palette is frozen data. So a user who changes the default theme sees the same "only new strats changed" behavior; a user who edits a shared custom profile sees it apply everywhere. Two different mental models for what looks like the same knob.

Team accent colors themselves (`Settings.enemyBGColor`, `Settings.allyBGColor`, outlines — `lib/const/settings.dart:78-82`) are compile-time constants; the only user-facing control is the per-strategy neutral toggle, which greys them via `Settings.neutralTeamShade` (`:84-86`).

## Existing precedent for "apply to more than one place"

The multi-page case of this exact problem is already solved *within* a strategy:

- `applyMarkerSizesToAllPages` copies the live agent/ability size onto every page of the open strategy (`lib/providers/strategy_provider.dart:3694-3726`), surfaced by a banner when pages disagree (`markerSizesDifferAcrossPages`, `lib/providers/marker_sizes_sync.dart:7-31`; banner in `lib/widgets/settings_tab.dart:357`).
- `applyNeutralTeamColorsToAllPages` does the same for the neutral toggle and is invoked automatically when the toggle changes (`lib/providers/strategy_provider.dart:3728-3756`, wired at `lib/widgets/settings_tab.dart:345-355`).

There is no library-wide equivalent.

## Why it works this way (intent)

Per-strategy sizes are a feature, not an accident: a dense 5-page execute wants small markers, a single-page lineup diagram wants big ones, and a strategy must render identically when its `.ica` is imported on another machine — so the sizes travel with the file. The global sliders were deliberately scoped as defaults ("Set the marker styling each new strategy starts with", `lib/widgets/settings_tab.dart:396-397`). The user pain is that the scoping isn't what people expect and there's no bulk way to restyle an existing library.

## Options for making settings apply retroactively

### Option A: "Apply to existing strategies" bulk action (recommended)

Add an explicit action next to the "New strategy defaults" card: after changing the default, offer "Apply these sizes to all existing strategies" (or per-folder). Implementation is a straight generalization of `applyMarkerSizesToAllPages` — iterate the `strategies` box, `copyWith` every page's `settings`, and `put` back:

```dart
for (final strat in strategiesBox.values) {
  final pages = [for (final p in strat.pages)
      p.copyWith(settings: p.settings.copyWith(agentSize: ..., abilitySize: ...))];
  await strategiesBox.put(strat.id, strat.copyWith(pages: pages));
}
```

Care points: skip (or reconcile with) the currently open strategy, whose live state is in `strategySettingsProvider`, not Hive — same reason `applyMarkerSizesToAllPages` calls `_syncCurrentPageToHive()` first (`:3697`). This is a bulk write over the whole library, so it must go through the normal model (never hand-edit serialized bytes) and should be undo-less but explicit — a confirmation dialog, since it overwrites deliberate per-strategy choices.

- **Pros:** no schema change, no migration, `.ica` round-trip untouched, per-strategy customization preserved, user stays in control.
- **Cons:** one-shot — future default changes need the button pressed again; O(library) write.

### Option B: inherit-unless-overridden (live reference semantics)

Make `StrategySettings` values nullable ("not set" = follow the current global preference), resolving at render time the way map theme profiles already do via `effectiveMapThemePaletteProvider`. A strategy only stores a concrete size once the user touches its per-strategy slider.

- **Pros:** matches user expectation permanently; consistent with the theme-profile model; future default changes propagate for free.
- **Cons:** significant cost. It's a Hive schema change (`StrategySettings` fields become nullable → adapters regenerate + a migration in `lib/migrations/`), and it breaks render-identical export: an `.ica` with "inherit" markers looks different on a machine with different defaults, so export would have to resolve to concrete values at write time (and import would then re-freeze them, partially defeating the point). Every existing strategy already has concrete values stored, so old strats would still need Option A's bulk "reset to inherit" pass anyway.

Given "the library is sacred" and the round-trip requirement, **Option A** delivers the user-visible fix at a fraction of the risk; Option B is only worth it if inheritance is wanted as a permanent semantic, and even then it should resolve to concrete values at `.ica` export.

A smaller companion fix either way: when the user changes a *default*, show an inline hint ("This affects new strategies — apply to existing ones?") so the scoping is discoverable, mirroring the existing `_PageMarkerSizesSyncBanner` pattern.
