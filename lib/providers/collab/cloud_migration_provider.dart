import 'dart:async';
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
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/strategy/strategy_cloud_migration.dart';
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
          iconId: folder.iconId,
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
      final pages = [...strategy.pages]
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      final firstPage = pages.isNotEmpty ? pages.first : null;
      final fallbackPageId = const Uuid().v4();
      try {
        await repo.createStrategyWithInitialPage(
          publicId: strategy.id,
          name: strategy.name,
          mapData: Maps.mapNames[strategy.mapData] ?? 'ascent',
          initialPagePublicId: firstPage?.id ?? fallbackPageId,
          initialPageName: firstPage?.name ?? 'Page 1',
          initialPageIsAttack: firstPage?.isAttack ?? true,
          initialPageSettings: firstPage == null
              ? ref.read(strategySettingsProvider).toJson()
              : firstPage.settings.toJson(),
          folderPublicId: strategy.folderID,
          themeProfileId: strategy.themeProfileId,
          themeOverridePalette: strategy.themeOverridePalette?.toJson(),
        );
      } catch (error, stackTrace) {
        await _maybeReportCloudUnauthenticated(
          source: 'cloud_migration:create_strategy',
          error: error,
          stackTrace: stackTrace,
        );
      }

      final allOps = <StrategyOp>[];
      final usedElementIds = <String>{};
      final usedLineupIds = <String>{};
      for (var i = 0; i < pages.length; i++) {
        final page = pages[i];
        if (i == 0) {
          appendMigratedPageOps(
            allOps,
            page,
            usedElementIds: usedElementIds,
            usedLineupIds: usedLineupIds,
          );
          continue;
        }
        try {
          await ConvexClient.instance.mutation(name: 'pages:add', args: {
            'strategyPublicId': strategy.id,
            'pagePublicId': page.id,
            'name': page.name,
            'sortIndex': page.sortIndex,
            'isAttack': page.isAttack,
            'settings': page.settings.toJson(),
          });
        } catch (error, stackTrace) {
          await _maybeReportCloudUnauthenticated(
            source: 'cloud_migration:add_page',
            error: error,
            stackTrace: stackTrace,
          );
        }

        appendMigratedPageOps(
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
