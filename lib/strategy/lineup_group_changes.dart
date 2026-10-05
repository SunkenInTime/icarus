import 'dart:convert';

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:uuid/uuid.dart';

/// What happened to one lineup between two versions of its group.
class LineupChange {
  const LineupChange({required this.label, required this.description});

  /// The lineup as the user knows it: its name, or its agent's.
  final String label;

  /// What changed, e.g. "added" or "notes edited, landing moved".
  final String description;
}

/// The lineups that differ between [from] and [to], one entry each, in
/// [to]'s order and then the lineups only [from] has.
List<LineupChange> lineupChanges({
  required LineUpGraph from,
  required LineUpGraph to,
}) {
  final before = _Lookup(from);
  final after = _Lookup(to);
  final changes = <LineupChange>[];
  for (final link in to.links) {
    final old = before.links[link.id];
    if (old == null) {
      changes.add(LineupChange(label: after.label(link), description: 'added'));
      continue;
    }
    final what = [
      if (old.name != link.name) 'renamed',
      if (old.notes != link.notes) 'notes edited',
      if (old.youtubeLink != link.youtubeLink) 'video changed',
      if (!_sameJson(
        [for (final image in old.images) image.toJson()],
        [for (final image in link.images) image.toJson()],
      ))
        'images changed',
      if (!_sameJson(
        before.origins[old.originId]?.toJson(),
        after.origins[link.originId]?.toJson(),
      ))
        'standing spot moved',
      if (!_sameJson(
        before.landings[old.landingId]?.toJson(),
        after.landings[link.landingId]?.toJson(),
      ))
        'landing moved',
    ];
    if (what.isNotEmpty) {
      changes.add(
        LineupChange(label: after.label(link), description: what.join(', ')),
      );
    }
  }
  for (final link in from.links) {
    if (!after.links.containsKey(link.id)) {
      changes.add(
        LineupChange(label: before.label(link), description: 'deleted'),
      );
    }
  }
  return changes;
}

/// A copy of [graph] under fresh ids, for keeping it beside the version it
/// conflicted with: its lineups, spots, and the agent and ability on each
/// spot are all new, so nothing in it is the original. Images stay the same
/// images.
LineUpGraph forkLineUpGraph(LineUpGraph graph) {
  const uuid = Uuid();
  final originIds = {for (final origin in graph.origins) origin.id: uuid.v4()};
  final landingIds = {
    for (final landing in graph.landings) landing.id: uuid.v4(),
  };
  return LineUpGraph(
    origins: [
      for (final origin in graph.origins)
        LineUpOrigin(
          id: originIds[origin.id]!,
          agent: origin.agent.copyWith(
            id: uuid.v4(),
            lineUpID: originIds[origin.id],
          )..isDeleted = origin.agent.isDeleted,
        ),
    ],
    landings: [
      for (final landing in graph.landings)
        LineUpLanding(
          id: landingIds[landing.id]!,
          ability: landing.ability.copyWith(
            id: uuid.v4(),
            lineUpID: landingIds[landing.id],
          )..isDeleted = landing.ability.isDeleted,
        ),
    ],
    links: [
      for (final link in graph.links)
        if ((originIds[link.originId], landingIds[link.landingId])
            case (final originId?, final landingId?))
          link.copyWith(
            id: uuid.v4(),
            originId: originId,
            landingId: landingId,
          ),
    ],
  );
}

/// Model `toJson()` output can nest objects with their own `toJson`, so it
/// goes through a plain JSON round trip before the canonical comparison.
bool _sameJson(Object? a, Object? b) =>
    canonicalCloudJsonEncode(jsonDecode(jsonEncode(a))) ==
    canonicalCloudJsonEncode(jsonDecode(jsonEncode(b)));

class _Lookup {
  _Lookup(LineUpGraph graph)
      : origins = {for (final origin in graph.origins) origin.id: origin},
        landings = {for (final landing in graph.landings) landing.id: landing},
        links = {for (final link in graph.links) link.id: link};

  final Map<String, LineUpOrigin> origins;
  final Map<String, LineUpLanding> landings;
  final Map<String, LineUpLink> links;

  String label(LineUpLink link) {
    final name = link.name.trim();
    if (name.isNotEmpty) return name;
    final agent = AgentData.agents[origins[link.originId]?.agent.type]?.name;
    return agent == null ? 'Unnamed lineup' : '$agent lineup';
  }
}
