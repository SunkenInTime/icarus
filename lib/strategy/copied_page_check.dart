import 'dart:convert';
import 'dart:math' show max;

import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/drawing_provider.dart';

/// The newest payload version this build reads.
final _newestReadablePayloadVersion =
    max(currentCloudPayloadVersion, paranoiaCloudPayloadVersion);

/// Whether every row of [page], read from this computer's copy, can be
/// drawn: each element and lineup group decodes the way hydration decodes
/// live rows (see strategy_page_source.dart), at a payload version this
/// build reads.
///
/// A copied page that fails is treated as not kept, never drawn without
/// the row: the editor's sync base would still hold the row, so a later
/// save could read its absence as a deletion. A live page doesn't go
/// through this; its rows are the server's, and hydration skips one it
/// can't read.
bool copiedPageIsDrawable(RemotePageSnapshot page) {
  for (final element in page.elements) {
    if (element.deleted) continue;
    if (!_readableVersion(element.payload)) return false;
    try {
      if (!_drawsElement(element.elementType, element.decodedPayload())) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }
  final lineups = [
    for (final lineup in page.lineups)
      if (!lineup.deleted) lineup,
  ];
  if (!lineups.every((lineup) => _readableVersion(lineup.payload))) {
    return false;
  }
  try {
    lineUpGraphFromCloudRows(lineups.map(CloudLineupRow.remote));
  } catch (_) {
    return false;
  }
  return true;
}

bool _readableVersion(CloudPayload payload) {
  final version = payload['payloadVersion'];
  return version is num && version <= _newestReadablePayloadVersion;
}

/// Hydration's decode of one element (strategy_page_source.dart): false
/// for a drawing that decodes to nothing, which hydration would skip.
bool _drawsElement(String elementType, Map<String, dynamic> data) {
  switch (elementType) {
    case 'agent':
      PlacedAgentNode.fromJson(data);
    case 'ability':
      PlacedAbility.fromJson(data);
    case 'drawing':
      return DrawingProvider.fromJson(jsonEncode([data])).isNotEmpty;
    case 'text':
      PlacedText.fromJson(data);
    case 'image':
      PlacedImage.fromJson(data);
    case 'utility':
      PlacedUtility.fromJson(data);
    default:
      return false;
  }
  return true;
}
