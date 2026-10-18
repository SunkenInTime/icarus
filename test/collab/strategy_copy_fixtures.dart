import 'package:icarus/collab/transport/convex_transport.dart';

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
        'data': {'id': id, 'x': x},
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
        'data': {'id': id, 'assetId': pictureId},
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
      'payload': {
        'kind': 'lineups',
        'payloadVersion': 1,
        'data': {
          'links': [
            {
              'images': [
                {'id': imageId},
              ],
            },
          ],
        },
      },
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
