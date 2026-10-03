import 'dart:math' show min;

import 'package:icarus/const/line_provider.dart';

/// The server's copy of a page's items ([incoming]), except the ones [keep]
/// names: those stay the object on screen, so the widget keeps whatever
/// in-progress state it holds, and stay even when the server removed them.
///
/// Items keep the server's order. A kept item the server removed keeps its
/// place on screen, so live sync, which reads order from list position, sees
/// no move the user never made.
List<T> mergeRemoteItems<T>({
  required List<T> current,
  required List<T> incoming,
  required String Function(T item) idOf,
  required bool Function(String id) keep,
}) {
  final currentById = {for (final item in current) idOf(item): item};
  final incomingIds = {for (final item in incoming) idOf(item)};
  final merged = [
    for (final item in incoming)
      if (currentById[idOf(item)] case final onScreen? when keep(idOf(item)))
        onScreen
      else
        item,
  ];
  for (final (index, item) in current.indexed) {
    if (!incomingIds.contains(idOf(item)) && keep(idOf(item))) {
      merged.insert(min(index, merged.length), item);
    }
  }
  return merged;
}

/// The server's lineups ([remote]), except the ones the user is holding:
/// those stay as the canvas ([local]) has them, as [mergeRemoteItems] keeps
/// held items. Returns the merged graph and the lineup groups held.
///
/// The user holds a lineup group by holding one of its lineups or spots;
/// [groupOf] names the group of a lineup or spot, local or remote. A group
/// is one cloud row, so it takes one side whole: every lineup in a held
/// group, and every lineup sharing a spot with one, stays as the canvas has
/// it. The other lineups take the server's copy. A held lineup only the
/// server has (a teammate's new lineup in a held group) waits off the
/// canvas until the hold ends, like a held lineup the server removed waits
/// on it.
(LineUpGraph, Set<String>) mergeHeldLineups({
  required LineUpGraph local,
  required LineUpGraph remote,
  required Set<String> holding,
  required String? Function(String id) groupOf,
}) {
  final allLinks = [...local.links, ...remote.links];
  final held = <String>{};
  final heldIds = {...holding};
  final heldGroups = {
    for (final id in holding)
      if (groupOf(id) case final group?) group,
  };
  for (var grew = true; grew;) {
    grew = false;
    for (final link in allLinks) {
      if (held.contains(link.id)) continue;
      final group = groupOf(link.id);
      if (heldIds.contains(link.id) ||
          heldIds.contains(link.originId) ||
          heldIds.contains(link.landingId) ||
          heldGroups.contains(group)) {
        held.add(link.id);
        heldIds.addAll([link.originId, link.landingId]);
        if (group != null) heldGroups.add(group);
        grew = true;
      }
    }
  }
  if (held.isEmpty) return (remote, heldGroups);

  final localLinks = {for (final link in local.links) link.id: link};
  final remoteLinkIds = {for (final link in remote.links) link.id};
  final links = [
    for (final link in remote.links)
      if (!held.contains(link.id))
        link
      else if (localLinks[link.id] case final onScreen?)
        onScreen,
  ];
  for (final (index, link) in local.links.indexed) {
    if (held.contains(link.id) && !remoteLinkIds.contains(link.id)) {
      links.insert(min(index, links.length), link);
    }
  }

  final originIds = {for (final link in links) link.originId};
  final landingIds = {for (final link in links) link.landingId};
  return (
    LineUpGraph(
      origins: [
        for (final origin in mergeRemoteItems(
          current: local.origins,
          incoming: remote.origins,
          idOf: (origin) => origin.id,
          keep: heldIds.contains,
        ))
          if (originIds.contains(origin.id)) origin,
      ],
      landings: [
        for (final landing in mergeRemoteItems(
          current: local.landings,
          incoming: remote.landings,
          idOf: (landing) => landing.id,
          keep: heldIds.contains,
        ))
          if (landingIds.contains(landing.id)) landing,
      ],
      links: links,
    ),
    heldGroups,
  );
}
