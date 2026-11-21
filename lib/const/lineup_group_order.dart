import 'package:icarus/const/line_provider.dart';

extension LineUpGroupOrder on LineUpGraph {
  List<LineUpGraph> groupsBy(String Function(LineUpLink link) groupOf) {
    final linksByGroup = <String, List<LineUpLink>>{};
    for (final link in links) {
      (linksByGroup[groupOf(link)] ??= []).add(link);
    }
    return [
      for (final groupLinks in linksByGroup.values) _withSpotsOf(groupLinks),
    ];
  }

  LineUpGraph get inGroupOrder {
    final originIds = {for (final origin in origins) origin.id};
    final landingIds = {for (final landing in landings) landing.id};
    final aimed = [
      for (final link in links)
        if (originIds.contains(link.originId) &&
            landingIds.contains(link.landingId))
          link,
    ];
    final groupOf = sharedSpotGroups(aimed);
    final groups = LineUpGraph(
      origins: origins,
      landings: landings,
      links: aimed,
    ).groupsBy((link) => groupOf[link.id]!);
    final grouped = LineUpGraph(
      origins: [for (final group in groups) ...group.origins],
      landings: [for (final group in groups) ...group.landings],
      links: [for (final group in groups) ...group.links],
    );
    return grouped.followedBy(this);
  }

  LineUpGraph withLineUpsPlaced(
    LineUpGraph incoming, {
    LineUpOrder formerly = LineUpOrder.none,
  }) {
    return LineUpGraph(
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
      links: _placed(links, incoming.links, formerly.links, (link) => link.id),
    ).inGroupOrder;
  }

  LineUpGraph followedBy(LineUpGraph rest) => LineUpGraph(
        origins: _appended(origins, rest.origins, (origin) => origin.id),
        landings: _appended(landings, rest.landings, (landing) => landing.id),
        links: _appended(links, rest.links, (link) => link.id),
      );

  LineUpGraph _withSpotsOf(List<LineUpLink> groupLinks) {
    final originIds = {for (final link in groupLinks) link.originId};
    final landingIds = {for (final link in groupLinks) link.landingId};
    return LineUpGraph(
      origins: [
        for (final origin in origins)
          if (originIds.contains(origin.id)) origin,
      ],
      landings: [
        for (final landing in landings)
          if (landingIds.contains(landing.id)) landing,
      ],
      links: groupLinks,
    );
  }
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

Map<String, String> sharedSpotGroups(Iterable<LineUpLink> links) {
  final parent = <String, String>{};
  String find(String node) {
    final up = parent[node] ?? node;
    if (up == node) return node;
    return parent[node] = find(up);
  }

  void union(String a, String b) {
    final rootA = find(a);
    final rootB = find(b);
    if (rootA != rootB) parent[rootA] = rootB;
  }

  for (final link in links) {
    union('k:${link.id}', 'o:${link.originId}');
    union('k:${link.id}', 'l:${link.landingId}');
  }
  return {for (final link in links) link.id: find('k:${link.id}')};
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
