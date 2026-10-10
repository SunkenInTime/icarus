import 'dart:convert';

import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:uuid/uuid.dart';

void appendMigratedPageOps(
  List<StrategyOp> ops,
  StrategyPage page, {
  required Set<String> usedElementIds,
  required Set<String> usedLineupIds,
}) {
  var elementOrder = 0;

  for (final agent in page.agentData) {
    final elementId = nextUniqueMigrationId(agent.id, usedElementIds);
    final payload = Map<String, dynamic>.from(agent.toJson())
      ..putIfAbsent('elementType', () => 'agent')
      ..['id'] = elementId;
    ops.add(
        buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final ability in page.abilityData) {
    final elementId = nextUniqueMigrationId(ability.id, usedElementIds);
    final payload = Map<String, dynamic>.from(ability.toJson())
      ..putIfAbsent('elementType', () => 'ability')
      ..['id'] = elementId;
    ops.add(
        buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final drawing in page.drawingData) {
    final elementId = nextUniqueMigrationId(drawing.id, usedElementIds);
    final encodedList =
        jsonDecode(DrawingProvider.objectToJson([drawing])) as List<dynamic>;
    final payload = Map<String, dynamic>.from(
      (encodedList.isNotEmpty ? encodedList.first : <String, dynamic>{}) as Map,
    )
      ..putIfAbsent('elementType', () => 'drawing')
      ..['id'] = elementId;
    ops.add(
        buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final text in page.textData) {
    final elementId = nextUniqueMigrationId(text.id, usedElementIds);
    final payload = Map<String, dynamic>.from(text.toJson())
      ..putIfAbsent('elementType', () => 'text')
      ..['id'] = elementId;
    ops.add(
        buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final image in page.imageData) {
    final elementId = nextUniqueMigrationId(image.id, usedElementIds);
    // A renamed image keeps showing its picture, which is stored under its
    // old id.
    final payload = cloudImagePayloadFromPlacedImage(
      elementId == image.id ? image : image.copyWith(assetId: image.pictureId),
    )
      ..putIfAbsent('elementType', () => 'image')
      ..['id'] = elementId;
    ops.add(
        buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final utility in page.utilityData) {
    final elementId = nextUniqueMigrationId(utility.id, usedElementIds);
    final payload = Map<String, dynamic>.from(utility.toJson())
      ..putIfAbsent('elementType', () => 'utility')
      ..['id'] = elementId;
    ops.add(
        buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  // One row per lineup group. A group's id must be unique in the strategy,
  // so one whose id another page already took (a page duplicated before
  // cloud sync repeats its lineup ids) takes another of its lineup ids.
  // Ids inside a row only need to be unique in the row, so they stay.
  final rows = cloudLineupRows(
    page.lineUpGraph,
    takenGroupIds: usedLineupIds,
  ).rows;
  usedLineupIds.addAll([for (final row in rows) row.publicId]);
  var lineupOrder = 0;
  for (final row in rows) {
    ops.add(
      LineupAddOp(
        opId: const Uuid().v4(),
        lineupPublicId: row.publicId,
        pagePublicId: page.id,
        payload: row.payload,
        sortIndex: lineupOrder++,
      ),
    );
  }
}

String nextUniqueMigrationId(String preferredId, Set<String> usedIds) {
  if (usedIds.add(preferredId)) {
    return preferredId;
  }

  var generated = const Uuid().v4();
  while (!usedIds.add(generated)) {
    generated = const Uuid().v4();
  }
  return generated;
}

StrategyOp buildMigratedElementOp(
  String pagePublicId,
  String elementId,
  Map<String, dynamic> payload,
  int sortIndex,
) {
  return ElementAddOp(
    opId: const Uuid().v4(),
    elementPublicId: elementId,
    pagePublicId: pagePublicId,
    payload: cloudElementPayload(
      kind: payload['elementType'] as String? ?? 'generic',
      data: payload,
    ),
    sortIndex: sortIndex,
  );
}
