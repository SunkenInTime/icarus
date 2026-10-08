import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/presence/presence_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_presence_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';

/// The lineups and spots each open lineup dialog shows, by the dialog that
/// opened them, so having one open counts as editing it.
final openLineUpItemsProvider =
    NotifierProvider<OpenLineUpItemsNotifier, Map<Object, Set<String>>>(
  OpenLineUpItemsNotifier.new,
);

class OpenLineUpItemsNotifier extends Notifier<Map<Object, Set<String>>> {
  /// The page each dialog opened on: its items are that page's, and stay
  /// so if the page on screen changes while it is open.
  final Map<Object, String?> _pageOf = {};

  @override
  Map<Object, Set<String>> build() => const {};

  void open(Object owner, Set<String> itemIds) {
    _pageOf[owner] = ref.read(strategyPageSessionProvider).activePageId;
    state = {...state, owner: itemIds};
  }

  void close(Object owner) {
    _pageOf.remove(owner);
    if (!state.containsKey(owner)) return;
    state = {...state}..remove(owner);
  }

  /// The page [owner] opened on.
  String? pageOf(Object owner) => _pageOf[owner];
}

/// The lineup groups this user is editing on the page on screen: those of
/// the lineup spots they hold, the spot a lineup is being placed from, and
/// the lineups an open dialog shows. Null for none, and always null for a
/// reader who can only view: holding or opening a lineup is not editing it.
final myLineupEditingProvider = Provider<PresenceEditing?>((ref) {
  final canEdit = ref.watch(
    currentStrategyCapabilitiesProvider.select(
      (capabilities) => capabilities.canEditPages,
    ),
  );
  if (!canEdit) return null;
  final pageId =
      ref.watch(strategyPageSessionProvider.select((s) => s.activePageId));
  if (pageId == null) return null;
  final held = ref.watch(editorHeldEntitiesProvider) ?? const <String>{};
  final placement = ref.watch(lineUpProvider.select((s) => s.placement));
  final open = ref.watch(openLineUpItemsProvider);
  final openNotifier = ref.read(openLineUpItemsProvider.notifier);
  ref.watch(lineupGroupMemoryRevisionProvider);
  final liveSync = ref.read(activePageLiveSyncProvider.notifier);
  final groupIds = {
    for (final id in {
      ...held,
      if (placement?.pinnedOriginId case final id?) id,
      if (placement?.pinnedLandingId case final id?) id,
      for (final MapEntry(key: owner, value: ids) in open.entries)
        if (openNotifier.pageOf(owner) == pageId) ...ids,
    })
      if (liveSync.lineupGroupOf(pageId, id) case final group?) group,
  };
  if (groupIds.isEmpty) return null;
  return PresenceEditing(pageId: pageId, groupIds: groupIds);
});

/// Teammates editing the lineup group [itemId] (a lineup, origin or landing
/// on the page on screen) is in, one entry per person.
final lineupGroupEditorsProvider =
    Provider.autoDispose.family<List<PresencePeer>, String>((ref, itemId) {
  final pageId =
      ref.watch(strategyPageSessionProvider.select((s) => s.activePageId));
  if (pageId == null) return const [];
  ref.watch(lineupGroupMemoryRevisionProvider);
  final group = ref
      .read(activePageLiveSyncProvider.notifier)
      .lineupGroupOf(pageId, itemId);
  if (group == null) return const [];
  // Cursors move many times a second; rebuild only when who is editing
  // changes, by watching a key of them rather than the list itself.
  ref.watch(strategyPresenceProvider.select((s) => jsonEncode([
        for (final peer in s.editingLineupGroup(pageId, group))
          [peer.uid, peer.name],
      ])));
  return ref.read(strategyPresenceProvider).editingLineupGroup(pageId, group);
});
