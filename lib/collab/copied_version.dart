import 'dart:convert';

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

/// What a full read of a strategy was of: its header, with the reader's
/// role, as canonical JSON, and its content version. While the server's
/// answer to strategy:listContentVersions holds the same two, nothing a
/// full read returns has changed.
typedef CopiedVersion = ({String header, int contentVersion});

/// The version [answer], a strategy:getFullSnapshot answer, was read at, or
/// null when it was asked without includeContentVersion.
CopiedVersion? copiedVersionOf(ConvexObject answer) {
  final contentVersion = answer.value['contentVersion']?.toDart();
  final header = answer.value['header'];
  if (contentVersion is! num || header is! ConvexObject) return null;
  return copiedVersionFrom(header, contentVersion.toInt());
}

/// The version of a strategy whose header reads [header].
CopiedVersion copiedVersionFrom(ConvexObject header, int contentVersion) => (
      header: canonicalCloudJsonEncode(
        jsonDecode(jsonEncode(header.toDart())),
      ),
      contentVersion: contentVersion,
    );
