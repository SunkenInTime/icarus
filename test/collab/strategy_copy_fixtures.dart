import 'dart:convert';
import 'dart:ui' show Offset;

import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/placed_classes.dart';

/// [value] as JSON carries it, the way the server sends it.
Map<String, Object?> _wire(Object value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

/// Server answers shaped as strategy:getShell, page:getSnapshot and
/// strategy:getFullSnapshot send them, for tests of the offline copy.

Map<String, Object?> headerRow({int revision = 1, String name = 'Strategy'}) =>
    {
      'publicId': 'strategy',
      'name': name,
      'mapData': 'ascent',
      'revision': revision,
      'createdAt': 1.0,
      'updatedAt': 1.0,
      'themeProfileId': null,
      'themeOverridePalette': null,
      'role': 'owner',
    };

Map<String, Object?> pageRow(
  String id, {
  int revision = 1,
  int sortIndex = 0,
  String? name,
}) =>
    {
      'publicId': id,
      'strategyPublicId': 'strategy',
      'name': name ?? id,
      'sortIndex': sortIndex,
      'isAttack': true,
      'revision': revision,
      'createdAt': 1.0,
      'updatedAt': 1.0,
    };

Map<String, Object?> contentRow({int revision = 1}) => {
      'settings': null,
      'revision': revision,
      'createdAt': 1.0,
      'updatedAt': 1.0,
    };

Map<String, Object?> agentRow(
  String id,
  String pageId, {
  int revision = 1,
  bool deleted = false,
  double x = 0,
}) =>
    {
      'publicId': id,
      'strategyPublicId': 'strategy',
      'pagePublicId': pageId,
      'elementType': 'agent',
      'payload': {
        'kind': 'agent',
        'payloadVersion': 1,
        'data': _wire(PlacedAgent(
          id: id,
          type: AgentType.jett,
          position: Offset(x, 10),
        ).toJson()),
      },
      'sortIndex': 0,
      'revision': revision,
      'deleted': deleted,
      'createdAt': 1.0,
      'updatedAt': 1.0,
    };

Map<String, Object?> imageRow(String id, String pageId, String pictureId) => {
      'publicId': id,
      'strategyPublicId': 'strategy',
      'pagePublicId': pageId,
      'elementType': 'image',
      'payload': {
        'kind': 'image',
        'payloadVersion': 1,
        'data': _wire(PlacedImage(
          id: id,
          position: const Offset(20, 20),
          aspectRatio: 1,
          scale: 1,
          fileExtension: '.png',
          assetId: pictureId,
        ).toJson()),
      },
      'sortIndex': 1,
      'revision': 1,
      'deleted': false,
      'createdAt': 1.0,
      'updatedAt': 1.0,
    };

Map<String, Object?> lineupRow(String id, String pageId, String imageId) => {
      'publicId': id,
      'strategyPublicId': 'strategy',
      'pagePublicId': pageId,
      'payload': _wire(_lineupGroupPayload(id, imageId)),
      'sortIndex': 0,
      'revision': 1,
      'deleted': false,
      'createdAt': 1.0,
      'updatedAt': 1.0,
    };

Map<String, Object?> assetRow(String id) => {
      'publicId': id,
      'provider': 'r2',
      'uploadStatus': 'active',
      'fileExtension': '.png',
      'mimeType': 'image/png',
      'width': null,
      'height': null,
      'byteSize': null,
      'uploadedAt': null,
      'url': 'https://images.example/$id.png',
      'legacyStoragePath': null,
    };

ConvexObject shellAnswer(List<String> pageIds, {int revision = 1}) =>
    ConvexValue.fromDart({
      'header': headerRow(revision: revision),
      'pages': [
        for (final (index, id) in pageIds.indexed)
          pageRow(id, sortIndex: index),
      ],
    }) as ConvexObject;

ConvexObject pageAnswer(
  String pageId, {
  int revision = 1,
  List<Map<String, Object?>> elements = const [],
  List<Map<String, Object?>> lineups = const [],
  List<Map<String, Object?>> assets = const [],
}) =>
    ConvexValue.fromDart({
      'page': pageRow(pageId, revision: revision),
      'content': contentRow(),
      'elements': elements,
      'lineups': lineups,
      'assets': assets,
    }) as ConvexObject;

ConvexObject fullAnswer(
  List<String> pageIds, {
  int revision = 1,
  List<Map<String, Object?>> elements = const [],
  List<Map<String, Object?>> lineups = const [],
  List<Map<String, Object?>> assets = const [],
}) =>
    ConvexValue.fromDart({
      'header': headerRow(revision: revision),
      'pages': [
        for (final (index, id) in pageIds.indexed)
          {
            ...pageRow(id, sortIndex: index),
            'settings': null,
            'contentRevision': 1,
            'contentCreatedAt': 1.0,
            'contentUpdatedAt': 1.0,
          },
      ],
      'elements': elements,
      'lineups': lineups,
      'assets': assets,
    }) as ConvexObject;

/// A real lineup group row's payload: one Sova lineup, [id], showing
/// [imageId]. Its group takes the lineup's id.
Map<String, dynamic> _lineupGroupPayload(String id, String imageId) {
  final graph = LineUpGraph(
    origins: [
      LineUpOrigin(
        id: '$id-origin',
        agent: PlacedAgent(
          id: '$id-agent',
          type: AgentType.sova,
          position: const Offset(10, 20),
          lineUpID: '$id-origin',
        ),
      ),
    ],
    landings: [
      LineUpLanding(
        id: '$id-landing',
        ability: PlacedAbility(
          id: '$id-ability',
          data: AgentData.agents[AgentType.sova]!.abilities[2],
          position: const Offset(30, 40),
          lineUpID: '$id-landing',
        ),
      ),
    ],
    links: [
      LineUpLink(
        id: id,
        originId: '$id-origin',
        landingId: '$id-landing',
        images: [SimpleImageData(id: imageId, fileExtension: '.png')],
      ),
    ],
  );
  final row = cloudLineupRows(graph).rows.single;
  if (row.publicId != id) throw StateError('group id ${row.publicId}');
  return row.payload;
}
