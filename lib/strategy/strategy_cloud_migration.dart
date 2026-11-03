import 'dart:convert';

import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:uuid/uuid.dart';

/// The cloud ids of the items of one strategy moving from this device.
///
/// Every item gets a fresh id: the server keeps one row per item id across
/// all strategies, and a local strategy shares its items' ids with every
/// local copy of it. An item that is on several pages (one id on each, or
/// copy ids of one root, see page_copy_id.dart) keeps one root in the cloud,
/// so the page transition still pairs it from page to page.
///
/// Pictures get fresh ids too: a picture's upload is queued under its id,
/// and a local strategy shares picture ids with its local copies and with
/// the cloud strategy it was exported from. [pictures] maps each local
/// picture id the moved content shows to its cloud id, with the file
/// extension the upload needs.
///
/// Lineup group ids only need to be unique in their strategy, so they stay;
/// [lineupGroupIds] holds the ones taken so far.
class MovedItemIds {
  final Map<String, String> _cloudRootByLocalRoot = {};
  final Set<String> lineupGroupIds = {};
  final Map<String, ({String cloudId, String fileExtension})> pictures = {};

  String cloudPictureIdFor(String localId, String fileExtension) {
    return pictures
        .putIfAbsent(
          localId,
          () => (cloudId: const Uuid().v4(), fileExtension: fileExtension),
        )
        .cloudId;
  }

  String cloudIdFor(String localId) {
    final localRoot = pageCopyRoot(localId);
    final cloudRoot = _cloudRootByLocalRoot[localRoot];
    if (cloudRoot == null) {
      return _cloudRootByLocalRoot[localRoot] = const Uuid().v4();
    }
    return newPageCopyId(cloudRoot);
  }
}

/// Adds to [ops] the content of [page] as it lands on the cloud page
/// [cloudPageId]: its items in the order the page draws them, then one row
/// per lineup group.
void appendMovedPageOps(
  List<StrategyOp> ops,
  StrategyPage page, {
  required String cloudPageId,
  required MovedItemIds ids,
}) {
  var elementOrder = 0;
  void addElement(String kind, String localId, Map<String, dynamic> data) {
    final elementId = ids.cloudIdFor(localId);
    data
      ..putIfAbsent('elementType', () => kind)
      ..['id'] = elementId;
    ops.add(
      ElementAddOp(
        opId: const Uuid().v4(),
        elementPublicId: elementId,
        pagePublicId: cloudPageId,
        payload: cloudElementPayload(kind: kind, data: data),
        sortIndex: elementOrder++,
      ),
    );
  }

  for (final agent in page.agentData) {
    addElement('agent', agent.id, Map<String, dynamic>.from(agent.toJson()));
  }
  for (final ability in page.abilityData) {
    addElement(
      'ability',
      ability.id,
      Map<String, dynamic>.from(ability.toJson()),
    );
  }
  for (final drawing in page.drawingData) {
    final encoded =
        jsonDecode(DrawingProvider.objectToJson([drawing])) as List<dynamic>;
    addElement(
      'drawing',
      drawing.id,
      Map<String, dynamic>.from(encoded.single as Map),
    );
  }
  for (final text in page.textData) {
    addElement('text', text.id, Map<String, dynamic>.from(text.toJson()));
  }
  for (final image in page.imageData) {
    addElement(
      'image',
      image.id,
      cloudImagePayloadFromPlacedImage(
        image.copyWith(
          assetId: ids.cloudPictureIdFor(
            image.pictureId,
            image.fileExtension ?? '',
          ),
        ),
      ),
    );
  }
  for (final utility in page.utilityData) {
    addElement(
      'utility',
      utility.id,
      Map<String, dynamic>.from(utility.toJson()),
    );
  }

  // A group's id must be unique in the strategy, so one whose id another
  // page already took (a page duplicated on this device repeats its lineup
  // ids) takes another of its lineup ids. Ids inside a row only need to be
  // unique in the row, so they stay.
  final graph = page.lineUpGraph;
  final originIds = {for (final origin in graph.origins) origin.id};
  final landingIds = {for (final landing in graph.landings) landing.id};
  final rows = cloudLineupRows(
    LineUpGraph(
      origins: graph.origins,
      landings: graph.landings,
      links: [
        for (final link in graph.links)
          // A lineup missing an end is not written (cloudLineupRows), so
          // its pictures are not moved.
          originIds.contains(link.originId) &&
                  landingIds.contains(link.landingId)
              ? link.copyWith(images: [
                  for (final image in link.images)
                    image.copyWith(
                      id: ids.cloudPictureIdFor(image.id, image.fileExtension),
                    ),
                ])
              : link,
      ],
    ),
    takenGroupIds: ids.lineupGroupIds,
  ).rows;
  ids.lineupGroupIds.addAll([for (final row in rows) row.publicId]);
  var lineupOrder = 0;
  for (final row in rows) {
    ops.add(
      LineupAddOp(
        opId: const Uuid().v4(),
        lineupPublicId: row.publicId,
        pagePublicId: cloudPageId,
        payload: row.payload,
        sortIndex: lineupOrder++,
      ),
    );
  }
}
