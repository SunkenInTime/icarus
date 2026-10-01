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
/// held items. Returns the merged graph and the ids of the held lineups.
///
/// A lineup is held when the user holds it, its origin or its landing, or
/// when it shares a spot with a held lineup: a shared spot is drawn once,
/// so every lineup on it takes the same side. The other lineups take the
/// server's copy. A held lineup only the server has (a teammate's new
/// lineup on a held spot) waits off the canvas until the hold ends, like a
/// held lineup the server removed waits on it.
(LineUpGraph, Set<String>) mergeHeldLineups({
  required LineUpGraph local,
  required LineUpGraph remote,
  required Set<String> holding,
}) {
  final allLinks = [...local.links, ...remote.links];
  final held = <String>{};
  final heldIds = {...holding};
  for (var grew = true; grew;) {
    grew = false;
    for (final link in allLinks) {
      if (held.contains(link.id)) continue;
      if (heldIds.contains(link.id) ||
          heldIds.contains(link.originId) ||
          heldIds.contains(link.landingId)) {
        held.add(link.id);
        heldIds.addAll([link.originId, link.landingId]);
        grew = true;
      }
    }
  }
  if (held.isEmpty) return (remote, held);

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
    held,
  );
}
