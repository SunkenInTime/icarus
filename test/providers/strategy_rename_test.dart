import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

void main() {
  test('renaming the open cloud strategy updates the name the title reads',
      () async {
    final repository = _RenameRepository();
    final container = ProviderContainer(overrides: [
      strategyProvider.overrideWith(() => _OpenStrategy(StrategySource.cloud)),
      remoteEditorSnapshotProvider.overrideWith(_OpenSnapshot.new),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(remoteEditorSnapshotProvider.future);

    await container.read(strategyProvider.notifier).renameStrategy(
          'strategy-1',
          'Renamed',
          source: StrategySource.cloud,
        );

    expect(repository.renamedTo, 'Renamed');
    expect(repository.expectedRevision, 4);
    expect(container.read(strategyProvider).strategyName, 'Renamed');
  });

  group('local (desktop)', () {
    late Directory hiveDir;

    setUp(() async {
      hiveDir = await Directory.systemTemp.createTemp('rename_test');
      Hive.init(hiveDir.path);
      registerIcarusAdapters(Hive);
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    });

    tearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });

    test('renaming the open local strategy updates the name the title reads',
        () async {
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      await box.put('strategy-1', _localStrategy('strategy-1', 'Original'));
      final container = ProviderContainer(overrides: [
        strategyProvider
            .overrideWith(() => _OpenStrategy(StrategySource.local)),
      ]);
      addTearDown(container.dispose);
      container.read(strategyProvider);

      await container.read(strategyProvider.notifier).renameStrategy(
            'strategy-1',
            'Renamed',
            source: StrategySource.local,
          );

      expect(box.get('strategy-1')!.name, 'Renamed');
      expect(container.read(strategyProvider).strategyName, 'Renamed');
    });
  });
}

class _OpenStrategy extends StrategyProvider {
  _OpenStrategy(this.source);

  final StrategySource source;

  @override
  StrategyState build() => StrategyState(
        strategyId: 'strategy-1',
        strategyName: 'Original',
        source: source,
        isOpen: true,
      );
}

class _OpenSnapshot extends RemoteEditorSnapshotNotifier {
  @override
  Future<RemoteEditorSnapshot?> build() async => RemoteEditorSnapshot(
        shell: RemoteStrategyShell(
          header: RemoteStrategyHeader(
            publicId: 'strategy-1',
            name: 'Original',
            mapData: 'Ascent',
            revision: 4,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
          pages: const [],
        ),
        activePage: null,
      );

  @override
  Future<void> refresh() async {}
}

class _RenameRepository extends ConvexStrategyRepository {
  _RenameRepository() : super(IcarusConvexApi(_UnusedTransport()));

  String? renamedTo;
  int? expectedRevision;

  @override
  Future<void> updateStrategyName({
    required String strategyPublicId,
    required String name,
    required int expectedRevision,
  }) async {
    renamedTo = name;
    this.expectedRevision = expectedRevision;
  }
}

class _UnusedTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

StrategyData _localStrategy(String id, String name) => StrategyData(
      id: id,
      name: name,
      mapData: MapValue.ascent,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.utc(2026),
      folderID: null,
      pages: const [],
    );
