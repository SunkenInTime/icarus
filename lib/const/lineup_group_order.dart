import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/line_provider.dart';

extension LineUpGroupOrder on LineUpGraph {
  LineUpGraph withLineUpsPlaced(
    LineUpGraph incoming, {
    LineupGroupMemory memory = LineupGroupMemory.none,
  }) =>
      lineUpsInGroupOrder(followedBy(incoming), memory: memory);

  LineUpGraph followedBy(LineUpGraph rest) => LineUpGraph(
        origins: _appended(origins, rest.origins, (origin) => origin.id),
        landings: _appended(landings, rest.landings, (landing) => landing.id),
        links: _appended(links, rest.links, (link) => link.id),
      );
}

List<T> _appended<T>(List<T> first, List<T> rest, String Function(T) idOf) {
  final present = {for (final entry in first) idOf(entry)};
  return [
    ...first,
    for (final entry in rest)
      if (present.add(idOf(entry))) entry,
  ];
}
