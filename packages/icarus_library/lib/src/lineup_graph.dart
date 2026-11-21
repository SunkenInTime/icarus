import 'json.dart';
import 'payloads.dart';

sealed class LineupCheck {
  const LineupCheck();
}

final class ValidLineupGroup extends LineupCheck {
  const ValidLineupGroup();
}

final class OtherLineupVersion extends LineupCheck {
  const OtherLineupVersion();
}

final class BrokenLineupGraph extends LineupCheck {
  const BrokenLineupGraph();
}

LineupCheck checkLineupPayload(
  LineupGroupPayload payload,
  String lineupPublicId,
) {
  if (payload.payloadVersion != lineupGroupPayloadVersion) {
    return const OtherLineupVersion();
  }
  final data = payload.data.raw;
  if (data['id'] != lineupPublicId || lineupPublicId.isEmpty) {
    return const BrokenLineupGraph();
  }
  final origins = _idsOf(data['origins'], 'agent');
  final landings = _idsOf(data['landings'], 'ability');
  final links = _idsOf(data['links'], null);
  if (origins == null || landings == null || links == null) {
    return const BrokenLineupGraph();
  }
  final linkList = data['links']! as List<Object?>;
  if (linkList.isEmpty) return const BrokenLineupGraph();
  for (final link in linkList.cast<Map<String, Object?>>()) {
    if (!origins.contains(link['originId']) ||
        !landings.contains(link['landingId'])) {
      return const BrokenLineupGraph();
    }
  }
  return const ValidLineupGroup();
}

Set<String>? _idsOf(Object? entries, String? markerKey) {
  if (entries is! List<Object?>) return null;
  final ids = <String>{};
  for (final entry in entries) {
    if (entry is! Map<String, Object?>) return null;
    final id = entry['id'];
    if (id is! String || id.isEmpty || !ids.add(id)) return null;
    if (markerKey != null && entry[markerKey] is! Map<String, Object?>) {
      return null;
    }
  }
  return ids;
}
