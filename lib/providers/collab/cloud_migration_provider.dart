import 'dart:async';
import 'dart:developer';

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

final cloudMigrationApiProvider = Provider<CloudMigrationApi>((ref) {
  return _DefaultCloudMigrationApi(
    ref.read(convexStrategyRepositoryProvider),
  );
});

abstract class CloudMigrationApi {
  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconId,
  });

  Future<void> createStrategyWithInitialPage({
    required String publicId,
    required String name,
    required String mapData,
    required String initialPagePublicId,
    required String initialPageName,
    required bool initialPageIsAttack,
    required Map<String, dynamic> initialPageSettings,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
  });

  Future<void> addPage({
    required String strategyPublicId,
    required String pagePublicId,
    required String name,
    required int sortIndex,
    required bool isAttack,
    required Map<String, dynamic> settings,
    required int expectedRevision,
  });

  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  });
}

class _DefaultCloudMigrationApi implements CloudMigrationApi {
  const _DefaultCloudMigrationApi(this._repository);

  final ConvexStrategyRepository _repository;

  @override
  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconId,
  }) {
    return _repository.createFolder(
      publicId: publicId,
      name: name,
      parentFolderPublicId: parentFolderPublicId,
      iconId: iconId,
    );
  }

  @override
  Future<void> createStrategyWithInitialPage({
    required String publicId,
    required String name,
    required String mapData,
    required String initialPagePublicId,
    required String initialPageName,
    required bool initialPageIsAttack,
    required Map<String, dynamic> initialPageSettings,
    String? folderPublicId,
    String? themeProfileId,
    Map<String, dynamic>? themeOverridePalette,
  }) {
    return _repository.createStrategyWithInitialPage(
      publicId: publicId,
      name: name,
      mapData: mapData,
      initialPagePublicId: initialPagePublicId,
      initialPageName: initialPageName,
      initialPageIsAttack: initialPageIsAttack,
      initialPageSettings: initialPageSettings,
      folderPublicId: folderPublicId,
      themeProfileId: themeProfileId,
      themeOverridePalette: themeOverridePalette,
    );
  }

  @override
  Future<void> addPage({
    required String strategyPublicId,
    required String pagePublicId,
    required String name,
    required int sortIndex,
    required bool isAttack,
    required Map<String, dynamic> settings,
    required int expectedRevision,
  }) async {
    await _repository.addPage(
      strategyPublicId: strategyPublicId,
      pagePublicId: pagePublicId,
      name: name,
      sortIndex: sortIndex,
      isAttack: isAttack,
      settings: settings,
      expectedRevision: expectedRevision,
    );
  }

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) {
    return _repository.applyBatch(
      strategyPublicId: strategyPublicId,
      clientId: clientId,
      ops: ops,
    );
  }
}

class CloudMigrationNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  Future<void> maybeMigrate() async {
    if (state) return;
    if (!ref.read(isCloudCollabEnabledProvider)) return;

    final api = ref.read(cloudMigrationApiProvider);
    final folders = Hive.box<Folder>(HiveBoxNames.foldersBox).values.toList();
    final strategies =
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).values.toList();
    var migrationSucceeded = true;

    Future<void> recordFailure({
      required String source,
      required Object error,
      required StackTrace stackTrace,
    }) async {
      migrationSucceeded = false;
      log(
        'Cloud migration write failed at $source: $error',
        name: 'cloud_migration',
        error: error,
        stackTrace: stackTrace,
      );
      await _maybeReportCloudUnauthenticated(
        source: source,
        error: error,
        stackTrace: stackTrace,
      );
    }

    for (final folder in folders) {
      try {
        await api.createFolder(
          publicId: folder.id,
          name: folder.name,
          parentFolderPublicId: folder.parentID,
          iconId: folder.iconId,
        );
      } catch (error, stackTrace) {
        await recordFailure(
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
        await api.createStrategyWithInitialPage(
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
        await recordFailure(
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
          await api.addPage(
            strategyPublicId: strategy.id,
            pagePublicId: page.id,
            name: page.name,
            sortIndex: page.sortIndex,
            isAttack: page.isAttack,
            settings: page.settings.toJson(),
            expectedRevision: i - 1,
          );
        } catch (error, stackTrace) {
          await recordFailure(
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
          final acknowledgements = await api.applyBatch(
            strategyPublicId: strategy.id,
            clientId: const Uuid().v4(),
            ops: allOps,
          );
          final rejected = acknowledgements.where((ack) => !ack.isAck).toList();
          if (acknowledgements.length != allOps.length || rejected.isNotEmpty) {
            final rejectionReasons = rejected
                .map((ack) => ack.reason ?? ack.status)
                .toSet()
                .join(', ');
            await recordFailure(
              source: 'cloud_migration:apply_batch',
              error: StateError(
                'Cloud migration batch was not fully acknowledged'
                '${rejectionReasons.isEmpty ? '' : ': $rejectionReasons'}',
              ),
              stackTrace: StackTrace.current,
            );
          }
        } catch (error, stackTrace) {
          await recordFailure(
            source: 'cloud_migration:apply_batch',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
    }

    state = migrationSucceeded;
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
