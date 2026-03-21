import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:uuid/uuid.dart';

final cloudMigrationProvider =
    NotifierProvider<CloudMigrationNotifier, bool>(CloudMigrationNotifier.new);

class CloudMigrationNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> maybeMigrate() async {
    if (state) return;
    if (!ref.read(isCloudCollabEnabledProvider)) return;

    final repo = ref.read(convexStrategyRepositoryProvider);
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox).values.toList();
    final strategies =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values.toList();

    for (final folder in folders) {
      try {
        await repo.createFolder(
          publicId: folder.id,
          name: folder.name,
          parentFolderPublicId: folder.parentID,
        );
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'cloud_migration:create_folder',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    for (final strategy in strategies) {
      try {
        await repo.createStrategy(
          publicId: strategy.id,
          name: strategy.name,
          mapData: Maps.mapNames[strategy.mapData] ?? 'ascent',
          folderPublicId: strategy.folderID,
          themeProfileId: strategy.themeProfileId,
          themeOverridePalette: strategy.themeOverridePalette == null
              ? null
              : jsonEncode(strategy.themeOverridePalette!.toJson()),
        );
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'cloud_migration:create_strategy',
          error: error,
          stackTrace: stackTrace,
        );
      }

      final pages = [...strategy.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

      final allOps = <StrategyOp>[];
      final usedElementIds = <String>{};
      final usedLineupIds = <String>{};
      for (final page in pages) {
        try {
          await ConvexClient.instance.mutation(name: 'pages:add', args: {
            'strategyPublicId': strategy.id,
            'pagePublicId': page.id,
            'name': page.name,
            'sortIndex': page.sortIndex,
            'isAttack': page.isAttack,
            'settings': StrategySettingsProvider.objectToJson(page.settings),
          });
        } catch (error, stackTrace) {
          await _maybeReportCloudUnauthenticated(
            source: 'cloud_migration:add_page',
            error: error,
            stackTrace: stackTrace,
          );
        }

        _appendPageElementOps(
          allOps,
          page,
          usedElementIds: usedElementIds,
          usedLineupIds: usedLineupIds,
        );
      }

      if (allOps.isNotEmpty) {
        try {
          await repo.applyBatch(
            strategyPublicId: strategy.id,
            clientId: const Uuid().v4(),
            ops: allOps,
          );
        } catch (error, stackTrace) {
          await _maybeReportCloudUnauthenticated(
            source: 'cloud_migration:apply_batch',
            error: error,
            stackTrace: stackTrace,
          );
          log('Cloud migration ops failed for ${strategy.id}: $error');
        }
      }
    }

    state = true;
  }

  void _appendPageElementOps(
    List<StrategyOp> ops,
    StrategyPage page, {
    required Set<String> usedElementIds,
    required Set<String> usedLineupIds,
  }) {
    var elementOrder = 0;

    for (final agent in page.agentData) {
      final elementId = _nextUniquePublicId(agent.id, usedElementIds);
      final payload = Map<String, dynamic>.from(agent.toJson())
        ..putIfAbsent('elementType', () => 'agent')
        ..['id'] = elementId;
      ops.add(_addElementOp(page.id, elementId, payload, elementOrder++));
    }

    for (final ability in page.abilityData) {
      final elementId = _nextUniquePublicId(ability.id, usedElementIds);
      final payload = Map<String, dynamic>.from(ability.toJson())
        ..putIfAbsent('elementType', () => 'ability')
        ..['id'] = elementId;
      ops.add(_addElementOp(page.id, elementId, payload, elementOrder++));
    }

    for (final drawing in page.drawingData) {
      final elementId = _nextUniquePublicId(drawing.id, usedElementIds);
      final encodedList =
          jsonDecode(DrawingProvider.objectToJson([drawing])) as List<dynamic>;
      final payload = Map<String, dynamic>.from(
        (encodedList.isNotEmpty ? encodedList.first : <String, dynamic>{}) as Map,
      )
        ..putIfAbsent('elementType', () => 'drawing')
        ..['id'] = elementId;
      ops.add(_addElementOp(page.id, elementId, payload, elementOrder++));
    }

    for (final text in page.textData) {
      final elementId = _nextUniquePublicId(text.id, usedElementIds);
      final payload = Map<String, dynamic>.from(text.toJson())
        ..putIfAbsent('elementType', () => 'text')
        ..['id'] = elementId;
      ops.add(_addElementOp(page.id, elementId, payload, elementOrder++));
    }

    for (final image in page.imageData) {
      final elementId = _nextUniquePublicId(image.id, usedElementIds);
      final payload = Map<String, dynamic>.from(image.toJson())
        ..putIfAbsent('elementType', () => 'image')
        ..['id'] = elementId;
      ops.add(_addElementOp(page.id, elementId, payload, elementOrder++));
    }

    for (final utility in page.utilityData) {
      final elementId = _nextUniquePublicId(utility.id, usedElementIds);
      final payload = Map<String, dynamic>.from(utility.toJson())
        ..putIfAbsent('elementType', () => 'utility')
        ..['id'] = elementId;
      ops.add(_addElementOp(page.id, elementId, payload, elementOrder++));
    }

    var lineupOrder = 0;
    for (final lineup in page.lineUps) {
      final lineupId = _nextUniquePublicId(lineup.id, usedLineupIds);
      final lineupPayload = Map<String, dynamic>.from(lineup.toJson())
        ..['id'] = lineupId;
      ops.add(StrategyOp(
        opId: const Uuid().v4(),
        kind: StrategyOpKind.add,
        entityType: StrategyOpEntityType.lineup,
        entityPublicId: lineupId,
        pagePublicId: page.id,
        payload: jsonEncode(lineupPayload),
        sortIndex: lineupOrder++,
      ));
    }
  }

  String _nextUniquePublicId(String preferredId, Set<String> usedIds) {
    if (usedIds.add(preferredId)) {
      return preferredId;
    }

    var generated = const Uuid().v4();
    while (!usedIds.add(generated)) {
      generated = const Uuid().v4();
    }
    return generated;
  }

  StrategyOp _addElementOp(
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

  Future<void> _maybeReportCloudUnauthenticated({
    required String source,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    if (!isConvexUnauthenticatedError(error)) {
      return;
    }

    await ref.read(authProvider.notifier).reportConvexUnauthenticated(
          source: source,
          error: error,
          stackTrace: stackTrace,
        );
  }
}
