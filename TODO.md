# Cloud UX overhaul — work list

Findings from the 2026-07-06 cloud UX audit. The cloud surfaces work, but they don't
meet the polish bar set by main (micro-interactions, shadcn consistency, state
feedback). Each section below is scoped as one PR into
`codex/reconcile-main-into-cloud`; the branch merges into `icarus-cloud` at the end.

Polish vocabulary to reuse (from main's recent work): 1.03 hover scale @150ms easeOut
(`folder_pill.dart`), 100–120ms border/background fades (`strategy_tile.dart`),
180ms rail expansion with delayed detail fade (`folder_navigator.dart`), 250ms search
expansion (`custom_search_field.dart`), shimmer skeleton (`strategy_view_skeleton.dart`).

## 1. Share dialogs redo — `lib/widgets/dialogs/share_links_dialog.dart`

- [x] Role clarity: two-line role options (what "View only"/"Can edit" grant), role
      badges (EDIT/VIEW/REVOKED) on each active link row
- [x] Link rows: code + relative created time instead of triple-wrapped URL; URL in tooltip
- [x] Copy buttons flash to a check (scale/fade, 120ms) alongside the toast
- [x] Revoke requires confirmation; spinner while revoking; revoked rows muted + strikethrough
- [x] Loading/error/empty/list states cross-fade (180ms); inline error card with Retry
- [x] Add-by-link dialog: inline validation errors + red input border (was: silent no-op),
      stays open on failed redemption (`redeemToken` now returns success), format shown
      in placeholder, Enter submits

## 2. Folder navigator side rail — `lib/widgets/folder_navigator_sidebar.dart`

- [ ] Narrow the panel (~288px → ~240px); reduce top-stack chrome
- [ ] Collapse the two stacked sort selects into one compact row (or move sorting into
      the content header)
- [ ] Remove the permanently-disabled "Cloud Tools" buttons in cloud mode
      (`Import .ica` / `Import Backup` / `Export Library` render disabled, ~120px dead space)
- [ ] Merge the duplicate Home entries in cloud mode ("Views → Home" vs root "Home" in Folders)
- [ ] Chevron expand/collapse for nested folders (tree is currently always fully expanded),
      150–180ms easeOutCubic reveal
- [ ] Row hover polish per main's vocabulary; drop the 500ms hover-exit timer on the "…" menu

## 3. Sync safety surfacing (trust-critical)

- [ ] Persistent sync-status chip in the editor top strip driven by
      `strategySaveStateProvider` (synced / syncing / offline / needs-attention),
      150ms state cross-fades — today pending/failed/offline are invisible until exit
- [ ] Wire up conflict surfacing: `strategyConflictProvider` is written
      (`strategy_page_session_provider.dart:718`) but watched by nothing — conflicts
      resolve silently
- [ ] Offline feedback ("working offline, will sync") — currently detected
      (`strategy_op_queue_provider.dart:371`) with zero UI
- [ ] Persistent indicator for failed media uploads (today: one toast on first failure,
      then invisible; ops silently dropped after 8 attempts)

## 4. Library loading / empty / error states + workspace transitions

- [ ] Skeleton grid while cloud lists load — `valueOrNull ?? []` currently shows
      "No cloud strategies yet" *during fetch* (`folder_content.dart:52`)
- [ ] Real error state with retry (auth/network failures currently yield empty lists
      that read as "you have no strategies", `remote_library_provider.dart:74-94`)
- [ ] Cloud-unavailable state to match the community placeholder's polish
      (icon + composition, `folder_content.dart:351-373`)
- [ ] 200–250ms cross-fade when switching Local ↔ Cloud workspace (currently instant)
- [ ] Disabled cloud rail items: opacity decay + transition when cloud becomes available

## 5. Cloud & role visibility in library and editor

- [ ] Cloud badge on cloud strategy tiles (currently identical to local,
      `folder_content.dart:249-263`)
- [ ] Owner/editor/viewer role badges on shared items in the library
- [ ] Role visibility in the editor (e.g. "View only" chip) — today role silently
      disables buttons with no explanation

## 6. Auth polish + Account settings

- [ ] Replace Material `AlertDialog` auth-incident prompt with ShadDialog
      (`auth_provider.dart:1137-1163`)
- [ ] Humanize error copy — no "Convex"/"Supabase"/"session" jargon
      (`auth_provider.dart:557, 576, 817, 1140`)
- [ ] Auth dialog: animated error presentation, input error borders, validation before
      submit-wait (`auth_dialog.dart:140-150`)
- [ ] OAuth: don't pop the dialog blind — show a pending state during the Discord round-trip
      (`auth_dialog.dart:179-187`)
- [ ] Sign-out feedback (toast) + loading affordance on the account rail item
- [ ] Account section in settings: email, sign out, cloud connection status
      (none exists today)
- [ ] Forgot-password / resend-confirmation affordances

## 7. Hardcoded color / theme sweep

- [ ] `strategy_tile_sections.dart:93-97` — `Colors.redAccent`/`lightBlueAccent`/
      `orangeAccent` for attack/defend labels → tactical palette
- [ ] `strategy_tile_sections.dart:284` — `Colors.deepPurpleAccent` drag border
- [ ] `strategy_tile.dart:198-200` — `Colors.redAccent` delete → `destructive`
- [ ] `folder_content.dart:276` — `Colors.grey` → `mutedForeground`
- [ ] `folder_navigator.dart:352-371` — `Colors.white` in popover buttons → theme foreground

## Done when

Every box above is checked, each PR has passed greptile review, and
`codex/reconcile-main-into-cloud` is merged into `icarus-cloud` (PR #78).
