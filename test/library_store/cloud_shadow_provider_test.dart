import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

import 'cloud_shadow_test.dart'
    show pageList, pageSnapshot, serverRows, strategyId;

class _Queue extends StrategyOpQueueNotifier {
  int? stamp = 0;

  @override
  StrategyOpQueueState build() => const StrategyOpQueueState();

  @override
  int? get liveStamp => stamp;
}

final class _Lists {
  final controllers = <StreamController<RemotePageList>>[];
  var cancelError = false;

  Stream<RemotePageList> watch() {
    late final StreamController<RemotePageList> controller;
    controller = StreamController<RemotePageList>(
      onCancel: () {
        if (cancelError) throw StateError('cancel broke');
      },
    );
    controllers.add(controller);
    return controller.stream;
  }
}

class _Repository implements ConvexStrategyRepository {
  _Repository(this.lists);

  final _Lists lists;

  @override
  ResultTap? tap;

  @override
  Stream<RemotePageList> watchPageList(
    String strategyPublicId, {
    String? shareToken,
  }) =>
      lists.watch();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _connected = StateProvider<bool>((ref) => true);

Future<void> _settled(CloudShadow shadow) async {
  for (var round = 0; round < 3; round++) {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await shadow.idle;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('with the flag off, the driver creates nothing of the shadow', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final log = CloudStoreLog();

    expect(log.isOn(container), isFalse);
    expect(log.drain(container), isEmpty);
    expect(await log.end(container, lastStep: DateTime.now()), isEmpty);
    expect(await log.readBack(container), isEmpty);
    expect(container.exists(cloudShadowProvider), isFalse);
  });

  group('through the provider', () {
    late ProviderContainer container;
    late _Queue queue;
    late _Lists lists;
    late _Repository repository;
    late Directory directory;
    late File file;
    var auth = (changes: 1, settled: true);

    Future<CloudShadow> begin({Future<LibraryStoreOpened>? opening}) async {
      await container.read(cloudShadowProvider.notifier).begin(
            opening: opening ?? openLibraryStore(file, build: 'b'),
            build: 'b',
          );
      return (container.read(cloudShadowProvider) as CloudShadowRunning).shadow;
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('icarus-cloud-tap-');
      file = File('${directory.path}/library.sqlite');
      auth = (changes: 1, settled: true);
      queue = _Queue();
      lists = _Lists();
      repository = _Repository(lists);
      container = ProviderContainer(overrides: [
        strategyOpQueueProvider.overrideWith(() => queue),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        convexConnectionSnapshotProvider
            .overrideWith((ref) => ref.watch(_connected)),
        authChangesProvider.overrideWithValue(() => auth),
      ]);
    });

    tearDown(() async {
      if (container.exists(cloudShadowProvider)) {
        await container.read(cloudShadowProvider.notifier).stopSubscriptions();
        if (container.read(cloudShadowProvider)
            case CloudShadowRunning(:final shadow)) {
          await shadow.idle;
          await shadow.store.close();
        }
      }
      container.dispose();
      await directory.delete(recursive: true);
    });

    test(
        'installs itself as the repository\'s tap, and starts a strategy\'s '
        'page list watch only after its first page has been handed over',
        () async {
      final shadow = await begin();
      expect(repository.tap, isNotNull);

      final issue = repository.tap!.issued();
      repository.tap!
          .pageArrived(strategyId, pageSnapshot(serverRows()), issue);
      expect(lists.controllers, isEmpty);
      await _settled(shadow);
      expect(lists.controllers, hasLength(1));
    });

    test(
        'a page answered on a new connection opens its session before it is '
        'recorded, though the connection change has not been reported',
        () async {
      final shadow = await begin();
      final rows = serverRows();
      final tap = repository.tap!;
      tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());
      await _settled(shadow);
      lists.controllers.single.add(pageList(rows));
      await _settled(shadow);

      queue.stamp = 1;
      final fresh = tap.issued();
      tap.pageArrived(strategyId, pageSnapshot(rows), fresh);
      await _settled(shadow);

      expect(shadow.ledger, hasLength(3));
      expect(shadow.ledger.last.verdict, isA<ComparedEqual>());
      expect(
        [
          for (final report in shadow.reports)
            if (report is ShadowSessionOpened) report.because,
        ],
        ['the strategy was added', 'the connection came back'],
      );
    });

    test(
        'a page read under one account and handed over after the account '
        'changed is skipped, never recorded under the new account', () async {
      final shadow = await begin();
      final rows = serverRows();
      final tap = repository.tap!;
      tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());
      await _settled(shadow);
      lists.controllers.single.add(pageList(rows));
      await _settled(shadow);

      final readAsFirst = tap.issued();
      auth = (changes: 2, settled: false);
      auth = (changes: 3, settled: true);
      tap.pageArrived(strategyId, pageSnapshot(rows), readAsFirst);
      final readAsSecond = tap.issued();
      tap.pageArrived(strategyId, pageSnapshot(rows), readAsSecond);
      await _settled(shadow);

      expect(shadow.ledger, hasLength(4));
      expect(
        shadow.ledger[2].verdict,
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.accountUnknown,
        ),
      );
      expect(shadow.ledger[3].verdict, isA<ComparedEqual>());
    });

    test(
        'a read issued while an account change is still under way is '
        'skipped', () async {
      final shadow = await begin();
      final rows = serverRows();
      final tap = repository.tap!;
      tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());
      await _settled(shadow);
      lists.controllers.single.add(pageList(rows));
      await _settled(shadow);

      auth = (changes: 2, settled: false);
      final during = tap.issued();
      tap.pageArrived(strategyId, pageSnapshot(rows), during);
      await _settled(shadow);

      expect(
        shadow.ledger.last.verdict,
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.accountUnknown,
        ),
      );
    });

    test('an error on the page list stream is an entry', () async {
      final shadow = await begin();
      final tap = repository.tap!;
      tap.pageArrived(strategyId, pageSnapshot(serverRows()), tap.issued());
      await _settled(shadow);

      lists.controllers.single.addError(StateError('the watch broke'));
      await _settled(shadow);

      expect(
        shadow.ledger.last,
        isA<LedgerEntry>()
            .having((entry) => entry.what, 'what', 'a read of the page list')
            .having((entry) => entry.verdict, 'verdict', isA<ReadFailed>()),
      );
    });

    test('a dropped connection is recorded', () async {
      final shadow = await begin();
      final rows = serverRows();
      final tap = repository.tap!;
      tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());
      await _settled(shadow);
      lists.controllers.single.add(pageList(rows));
      await _settled(shadow);

      container.read(_connected.notifier).state = false;
      await _settled(shadow);

      expect(shadow.reports.whereType<ShadowConnectionLost>(), hasLength(1));
    });

    test(
        'stopping takes the tap off the repository and closes the page list '
        'watches, so nothing is delivered after the cutoff', () async {
      final shadow = await begin();
      final rows = serverRows();
      final tap = repository.tap!;
      tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());
      await _settled(shadow);
      final controller = lists.controllers.single;

      await container.read(cloudShadowProvider.notifier).stopSubscriptions();
      final delivered = shadow.ledger.length;
      tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());

      expect(repository.tap, isNull);
      expect(controller.hasListener, isFalse);
      expect(shadow.ledger, hasLength(delivered));
    });

    test(
        'a cancellation that throws stops the shadow and reaches nothing '
        'else', () async {
      final shadow = await begin();
      final tap = repository.tap!;
      tap.pageArrived(strategyId, pageSnapshot(serverRows()), tap.issued());
      await _settled(shadow);
      lists.cancelError = true;

      await container.read(cloudShadowProvider.notifier).stopSubscriptions();

      expect(shadow.stopped, contains('cancel broke'));
    });

    test('a store open that throws leaves the shadow failed with the reason',
        () async {
      await container.read(cloudShadowProvider.notifier).begin(
            opening: Future.error(StateError('the disk broke')),
            build: 'b',
          );

      expect(
        container.read(cloudShadowProvider),
        isA<CloudShadowFailed>().having(
          (failed) => failed.reason,
          'reason',
          contains('the disk broke'),
        ),
      );
    });

    group('the end of a run', () {
      Future<void> closeStore(CloudShadow shadow) async {
        await container.read(libraryStoreProvider.notifier).close();
      }

      test('reads the store back from disk and compares each strategy whole',
          () async {
        final opened = await container
            .read(libraryStoreProvider.notifier)
            .open(file, build: 'b');
        final shadow = await begin(opening: Future.value(opened));
        final rows = serverRows();
        final tap = repository.tap!;
        tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());
        await _settled(shadow);
        lists.controllers.single.add(pageList(rows));
        await _settled(shadow);
        final log = CloudStoreLog();

        final verdict = await log.end(container, lastStep: DateTime.now());
        expect(verdict.where((line) => line.problem), isEmpty);
        await closeStore(shadow);
        final readBack = await log.readBack(container);

        expect(readBack.where((line) => line.problem), isEmpty);
        expect(readBack.single.text, contains('$strategyId equal, whole'));
      });

      test('an empty store file is not equal', () async {
        final opened = await container
            .read(libraryStoreProvider.notifier)
            .open(file, build: 'b');
        final shadow = await begin(opening: Future.value(opened));
        final rows = serverRows();
        final tap = repository.tap!;
        tap.pageArrived(strategyId, pageSnapshot(rows), tap.issued());
        await _settled(shadow);
        lists.controllers.single.add(pageList(rows));
        await _settled(shadow);
        final log = CloudStoreLog();
        await log.end(container, lastStep: DateTime.now());
        await closeStore(shadow);
        for (final entry in directory.listSync()) {
          entry.deleteSync();
        }

        final readBack = await log.readBack(container);
        expect(
          readBack.where((line) => line.problem).map((line) => line.text),
          contains(contains('the store does not hold the strategy')),
        );
      });

      test(
          'a run that never recorded a strategy fails its verdict and its '
          'read back', () async {
        final opened = await container
            .read(libraryStoreProvider.notifier)
            .open(file, build: 'b');
        final shadow = await begin(opening: Future.value(opened));
        final log = CloudStoreLog();
        final verdict = await log.end(container, lastStep: DateTime.now());
        await closeStore(shadow);
        final readBack = await log.readBack(container);

        expect(
          verdict.where((line) => line.problem).map((line) => line.text),
          contains('CLOUDSTORE no result was delivered'),
        );
        expect(
          readBack.where((line) => line.problem).map((line) => line.text),
          contains('CLOUDSTORE read back had no strategy to compare'),
        );
      });

      test('a page whose page list never came fails the verdict', () async {
        final opened = await container
            .read(libraryStoreProvider.notifier)
            .open(file, build: 'b');
        final shadow = await begin(opening: Future.value(opened));
        final tap = repository.tap!;
        tap.pageArrived(strategyId, pageSnapshot(serverRows()), tap.issued());
        await _settled(shadow);
        final log = CloudStoreLog();

        final verdict = await log.end(container, lastStep: DateTime.now());
        final problems = [
          for (final line in verdict)
            if (line.problem) line.text,
        ];
        expect(problems, contains(startsWith('CLOUDSTORE not processed:')));
        expect(
          problems,
          contains('CLOUDSTORE no result of $strategyId was compared equal'),
        );
        await closeStore(shadow);
      });
    });
  });
}
