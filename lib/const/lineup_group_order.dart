import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/line_provider.dart';

extension LineUpGroupOrder on LineUpGraph {
  LineUpGraph withLineUpsPlaced(
    LineUpGraph incoming, {
    LineUpOrder formerly = LineUpOrder.none,
    Map<String, String> groupOf = const {},
  }) {
    return lineUpsInGroupOrder(
      LineUpGraph(
        origins: _placed(
          origins,
          incoming.origins,
          formerly.origins,
          (origin) => origin.id,
        ),
        landings: _placed(
          landings,
          incoming.landings,
          formerly.landings,
          (landing) => landing.id,
        ),
        links:
            _placed(links, incoming.links, formerly.links, (link) => link.id),
      ),
      groupOf: groupOf,
    );
  }

  LineUpGraph followedBy(LineUpGraph rest) => LineUpGraph(
        origins: _appended(origins, rest.origins, (origin) => origin.id),
        landings: _appended(landings, rest.landings, (landing) => landing.id),
        links: _appended(links, rest.links, (link) => link.id),
      );
}

class LineUpOrder {
  const LineUpOrder({
    this.origins = const [],
    this.landings = const [],
    this.links = const [],
  });

  LineUpOrder.of(LineUpGraph graph)
      : origins = [for (final origin in graph.origins) origin.id],
        landings = [for (final landing in graph.landings) landing.id],
        links = [for (final link in graph.links) link.id];

  static const none = LineUpOrder();

  final List<String> origins;
  final List<String> landings;
  final List<String> links;
}

List<T> _appended<T>(List<T> first, List<T> rest, String Function(T) idOf) {
  final present = {for (final entry in first) idOf(entry)};
  return [
    ...first,
    for (final entry in rest)
      if (present.add(idOf(entry))) entry,
  ];
}

List<T> _placed<T>(
  List<T> current,
  List<T> incoming,
  List<String> formerly,
  String Function(T) idOf,
) {
  final placed = [...current];
  final present = {for (final entry in current) idOf(entry)};
  final formerIndex = {for (final (index, id) in formerly.indexed) id: index};
  final arriving = [
    for (final entry in incoming)
      if (!present.contains(idOf(entry))) entry,
  ];
  final known = [
    for (final entry in arriving)
      if (formerIndex.containsKey(idOf(entry))) entry,
  ]..sort((a, b) => formerIndex[idOf(a)]!.compareTo(formerIndex[idOf(b)]!));
  int indexOf(String id) => placed.indexWhere((entry) => idOf(entry) == id);
  String? firstPresent(Iterable<String> ids) {
    for (final id in ids) {
      if (present.contains(id)) return id;
    }
    return null;
  }

  for (final entry in known) {
    final at = formerIndex[idOf(entry)]!;
    final before = firstPresent(formerly.take(at).toList().reversed);
    final after = firstPresent(formerly.skip(at + 1));
    final position = switch ((before, after)) {
      (final before?, _) => indexOf(before) + 1,
      (null, final after?) => indexOf(after),
      (null, null) => placed.length,
    };
    placed.insert(position, entry);
    present.add(idOf(entry));
  }
  for (final entry in arriving) {
    if (present.add(idOf(entry))) placed.add(entry);
  }
  return placed;
}
