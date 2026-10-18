import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/page_changes.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:uuid/uuid.dart';

/// Pages a cloud strategy gets from "+" on this computer when the server
/// can't make the copy (offline, say): this computer copies the page on
/// screen itself, and the page exists only here until its add lands.

/// An item or lineup group as the canvas draws it, in cloud form.
typedef DrawnRow = ({String publicId, CloudPayload payload, int sortIndex});

/// The ops that put a copy of [elements] and [lineups] on [pageId], as the
/// server's copy does (convex/lib/contentCopy.ts): every item and every id
/// in a lineup group gets a copy id that keeps its root (see
/// page_copy_id.dart), each place stays as it was, and a copied image
/// shows its original's picture.
List<StrategyOp> pageCopyContentOps({
  required String pageId,
  required Iterable<DrawnRow> elements,
  required Iterable<DrawnRow> lineups,
}) {
  final newLineupId = _sharedCopyIds();
  return [
    for (final element in elements)
      _copiedElement(pageId, element, _copyId(element.publicId)),
    for (final lineup in lineups)
      _copiedLineupGroup(pageId, lineup, newLineupId),
  ];
}

/// [pageId] as this computer shows it while its add has not landed: the
/// page as the pages bar draws it, empty. What [add] and the work queued
/// for the page after it hold is drawn on top, as for any waiting work.
/// The server makes a page and its settings at revision 1, so work made on
/// it is made against that.
RemotePageSnapshot pageMadeHere({
  required String strategyPublicId,
  required PageAddOp add,
  required DrawnPage drawn,
  required int sortIndex,
  Map<String, RemoteImageAsset> assetsById = const {},
}) {
  final now = DateTime.now();
  return RemotePageSnapshot(
    page: RemotePage(
      publicId: add.pagePublicId,
      strategyPublicId: strategyPublicId,
      name: drawn.name,
      isAutoNamed: drawn.isAutoNamed,
      sortIndex: sortIndex,
      isAttack: drawn.isAttack,
      revision: 1,
      createdAt: now,
      updatedAt: now,
    ),
    content: RemotePageContent(
      settings: cloudObjectPayloadOrNull(add.payload['settings']),
      revision: 1,
      createdAt: now,
      updatedAt: now,
    ),
    elements: const [],
    lineups: const [],
    assetsById: assetsById,
    madeHere: true,
  );
}

/// The longest root a copy id keeps, URL-encoded, as the server's
/// (convex/lib/pageCopyId.ts): a longer one would make the op's storage
/// key too long to keep, so that copy gets a plain id.
const _maxKeptRootLength = 80;

String _copyId(String id) =>
    Uri.encodeComponent(pageCopyRoot(id)).length > _maxKeptRootLength
        ? const Uuid().v4()
        : newPageCopyId(id);

/// One copy id per id, shared by every lineup group copied: a spot or
/// lineup named twice is the same copy both times.
String Function(String id) _sharedCopyIds() {
  final ids = <String, String>{};
  return (id) => ids[id] ??= _copyId(id);
}

ElementAddOp _copiedElement(String pageId, DrawnRow element, String id) {
  final kind = element.payload['kind'] as String;
  final data = cloudPayloadData(element.payload);
  return ElementAddOp(
    opId: const Uuid().v4(),
    elementPublicId: id,
    pagePublicId: pageId,
    payload: cloudElementPayload(kind: kind, data: {
      ...data,
      'id': id,
      // A copied image shows its original's picture (see
      // PlacedImage.assetId): nothing is copied or uploaded.
      if (kind == 'image') 'assetId': data['assetId'] ?? element.publicId,
    }),
    sortIndex: element.sortIndex,
  );
}

/// A lineup group's row as the server's copy stores it (copiedLineupRow in
/// convex/lib/contentCopy.ts): its lineups and spots under new ids, each
/// link naming its ends' new ids and each marker's `lineUpID` following
/// its spot.
LineupAddOp _copiedLineupGroup(
  String pageId,
  DrawnRow group,
  String Function(String id) newId,
) {
  final data = cloudPayloadData(group.payload);
  String idOf(Object? value) => value is String ? value : '';
  List<Object?> entries(Object? value) => value is List ? value : const [];
  Object? copiedSpot(Object? spot, String markerKey) {
    if (spot is! Map) return spot;
    final id = newId(idOf(spot['id']));
    final marker = spot[markerKey];
    return {
      ...spot,
      'id': id,
      if (marker is Map) markerKey: {...marker, 'lineUpID': id},
    };
  }

  Object? copiedLink(Object? link) => link is Map
      ? {
          ...link,
          'id': newId(idOf(link['id'])),
          'originId': newId(idOf(link['originId'])),
          'landingId': newId(idOf(link['landingId'])),
        }
      : link;
  final id = newId(idOf(data['id']));
  return LineupAddOp(
    opId: const Uuid().v4(),
    lineupPublicId: id,
    pagePublicId: pageId,
    payload: cloudLineupsPayload({
      ...data,
      'id': id,
      'origins': [
        for (final origin in entries(data['origins']))
          copiedSpot(origin, 'agent'),
      ],
      'landings': [
        for (final landing in entries(data['landings']))
          copiedSpot(landing, 'ability'),
      ],
      'links': [for (final link in entries(data['links'])) copiedLink(link)],
    }),
    sortIndex: group.sortIndex,
  );
}
