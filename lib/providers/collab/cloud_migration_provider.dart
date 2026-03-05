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

        _appendPageElementOps(allOps, page);
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

  void _appendPageElementOps(List<StrategyOp> ops, StrategyPage page) {
    var elementOrder = 0;

    for (final agent in page.agentData) {
      final payload = Map<String, dynamic>.from(agent.toJson())
        ..putIfAbsent('elementType', () => 'agent');
      ops.add(_addElementOp(page.id, agent.id, payload, elementOrder++));
    }

    for (final ability in page.abilityData) {
      final payload = Map<String, dynamic>.from(ability.toJson())
        ..putIfAbsent('elementType', () => 'ability');
      ops.add(_addElementOp(page.id, ability.id, payload, elementOrder++));
    }

    for (final drawing in page.drawingData) {
      final encodedList =
          jsonDecode(DrawingProvider.objectToJson([drawing])) as List<dynamic>;
      final payload = Map<String, dynamic>.from(
        (encodedList.isNotEmpty ? encodedList.first : <String, dynamic>{}) as Map,
      )..putIfAbsent('elementType', () => 'drawing');
      ops.add(_addElementOp(page.id, drawing.id, payload, elementOrder++));
    }

    for (final text in page.textData) {
      final payload = Map<String, dynamic>.from(text.toJson())
        ..putIfAbsent('elementType', () => 'text');
      ops.add(_addElementOp(page.id, text.id, payload, elementOrder++));
    }

    for (final image in page.imageData) {
      final payload = Map<String, dynamic>.from(image.toJson())
        ..putIfAbsent('elementType', () => 'image');
      ops.add(_addElementOp(page.id, image.id, payload, elementOrder++));
    }

    for (final utility in page.utilityData) {
      final payload = Map<String, dynamic>.from(utility.toJson())
        ..putIfAbsent('elementType', () => 'utility');
      ops.add(_addElementOp(page.id, utility.id, payload, elementOrder++));
    }

    var lineupOrder = 0;
    for (final lineup in page.lineUps) {
      ops.add(StrategyOp(
        opId: const Uuid().v4(),
        kind: StrategyOpKind.add,
        entityType: StrategyOpEntityType.lineup,
        entityPublicId: lineup.id,
        pagePublicId: page.id,
        payload: jsonEncode(lineup.toJson()),
        sortIndex: lineupOrder++,
      ));
    }
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
