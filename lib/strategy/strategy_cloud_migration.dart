import 'dart:convert';

import 'package:icarus/collab/collab_models.dart';
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
    ops.add(buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final ability in page.abilityData) {
    final elementId = nextUniqueMigrationId(ability.id, usedElementIds);
    final payload = Map<String, dynamic>.from(ability.toJson())
      ..putIfAbsent('elementType', () => 'ability')
      ..['id'] = elementId;
    ops.add(buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
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
    ops.add(buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final text in page.textData) {
    final elementId = nextUniqueMigrationId(text.id, usedElementIds);
    final payload = Map<String, dynamic>.from(text.toJson())
      ..putIfAbsent('elementType', () => 'text')
      ..['id'] = elementId;
    ops.add(buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final image in page.imageData) {
    final elementId = nextUniqueMigrationId(image.id, usedElementIds);
    final payload = Map<String, dynamic>.from(image.toJson())
      ..putIfAbsent('elementType', () => 'image')
      ..['id'] = elementId;
    ops.add(buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  for (final utility in page.utilityData) {
    final elementId = nextUniqueMigrationId(utility.id, usedElementIds);
    final payload = Map<String, dynamic>.from(utility.toJson())
      ..putIfAbsent('elementType', () => 'utility')
      ..['id'] = elementId;
    ops.add(buildMigratedElementOp(page.id, elementId, payload, elementOrder++));
  }

  var lineupOrder = 0;
  for (final lineup in page.lineUps) {
    final lineupId = nextUniqueMigrationId(lineup.id, usedLineupIds);
    final lineupPayload = Map<String, dynamic>.from(lineup.toJson())
      ..['id'] = lineupId;
    ops.add(
      StrategyOp(
        opId: const Uuid().v4(),
        kind: StrategyOpKind.add,
        entityType: StrategyOpEntityType.lineup,
        entityPublicId: lineupId,
        pagePublicId: page.id,
        payload: jsonEncode(lineupPayload),
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
  return StrategyOp(
    opId: const Uuid().v4(),
    kind: StrategyOpKind.add,
    entityType: StrategyOpEntityType.element,
    entityPublicId: elementId,
    pagePublicId: pagePublicId,
    payload: jsonEncode(payload),
    sortIndex: sortIndex,
  );
}
