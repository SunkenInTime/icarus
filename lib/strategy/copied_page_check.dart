import 'dart:math' show max;

import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/strategy/cloud_element_decoding.dart';

/// The newest payload version this build reads.
final _newestReadablePayloadVersion =
    max(currentCloudPayloadVersion, paranoiaCloudPayloadVersion);

/// Whether every row of [page], read from this computer's copy, can be
/// drawn: each element decodes with hydration's decoder
/// ([decodeCloudElement]) and each lineup group as hydration reads it, at a
/// payload version this build reads.
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
      if (decodeCloudElement(element.elementType, element.decodedPayload()) ==
          null) {
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
