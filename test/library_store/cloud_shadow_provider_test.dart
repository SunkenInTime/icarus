import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/store_startup.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

import 'cloud_shadow_test.dart'
    show at, pageList, pageSnapshot, serverRows, strategyId;

class _Queue extends StrategyOpQueueNotifier {
  int? stamp = 0;

  @override
  StrategyOpQueueState build() => const StrategyOpQueueState();

  @override
  int? get liveStamp => stamp;
}

class _Editor extends RemoteEditorSnapshotNotifier {
  @override
  Future<RemoteEditorSnapshot?> build() async => null;

  void open(String? strategy) {
    state = AsyncData(
      strategy == null
          ? null
          : RemoteEditorSnapshot(
              shell: RemoteStrategyShell(
                header: RemoteStrategyHeader(
                  publicId: strategy,
                  name: 'Shell',
                  mapData: 'bind',
                  revision: 1,
                  createdAt: at,
                  updatedAt: at,
                ),
                pages: const [],
              ),
              activePage: null,
            ),
    );
  }
}

final class _Lists {
  final controllers = <StreamController<RemotePageList>>[];
  Future<void> Function()? onCancel;

  Stream<RemotePageList> watch() {
    final controller = StreamController<RemotePageList>(
      onCancel: () => onCancel?.call(),
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

Future<void> _settled() async {
  for (var round = 0; round < 6; round++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('with the flag off, start-up creates nothing of the shadow', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('icarus-startup-');
    });
    tearDown(() => directory.delete(recursive: true));

    test('neither flag: no store, no shadow, no driver lines', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final stores = openStores(
        container,
        LibraryStoreLaunch.parse(const [], mayShadow: true),
        hiveDirectory: directory.path,
        allowsLocalLibrary: true,
        build: 'b',
      );
      beginCloudShadow(container, stores, build: 'b');
      final log = CloudStoreLog();

      expect(stores.opening, isNull);
      expect(container.exists(cloudShadowProvider), isFalse);
      expect(log.drain(container), isEmpty);
      expect(await log.end(container, lastStep: DateTime.now()), isEmpty);
      expect(await log.readBack(container), isEmpty);
      expect(container.exists(cloudShadowProvider), isFalse);
    });

    test('the library store flag alone opens the store, still with no shadow',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final stores = openStores(
        container,
        LibraryStoreLaunch.parse(
          const ['--library-store=shadow'],
          mayShadow: true,
        ),
        hiveDirectory: directory.path,
        allowsLocalLibrary: true,
        build: 'b',
      );
      beginCloudShadow(container, stores, build: 'b');
      await stores.opening;

      expect(container.exists(cloudShadowProvider), isFalse);
      await container.read(libraryStoreProvider.notifier).close();
    });
  });

  group('through the provider', () {
    late ProviderContainer container;
    late _Queue queue;
    late _Editor editor;
    late _Lists lists;
    late _Repository repository;
    late Directory directory;
    late File file;
    late AuthChanges auth;

    Future<CloudShadow> begin({Future<LibraryStoreOpened>? opening}) async {
      await container.read(cloudShadowProvider.notifier).begin(
            opening: opening ??
                container
                    .read(libraryStoreProvider.notifier)
                    .open(file, build: 'b'),
            build: 'b',
          );
      return (container.read(cloudShadowProvider) as CloudShadowRunning).shadow;
    }

    ResultTap tap() => repository.tap!;

    void deliverPage(RemotePageSnapshot page, {bool throughShareLink = false}) {
      tap().pageArrived(
        strategyId,
        page,
        tap().heard(),
        throughShareLink: throughShareLink,
      );
    }

    Future<CloudShadow> opened() async {
      final shadow = await begin();
      editor.open(strategyId);
      await _settled();
      deliverPage(pageSnapshot(serverRows()));
      lists.controllers.single.add(pageList(serverRows()));
      await _settled();
      await shadow.idle;
      return shadow;
    }

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('icarus-cloud-tap-');
      file = File('${directory.path}/library.sqlite');
      auth = (changes: 1, authenticated: true);
      queue = _Queue();
      editor = _Editor();
      lists = _Lists();
      repository = _Repository(lists);
      container = ProviderContainer(overrides: [
        strategyOpQueueProvider.overrideWith(() => queue),
        remoteEditorSnapshotProvider.overrideWith(() => editor),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        convexConnectionSnapshotProvider
            .overrideWith((ref) => ref.watch(_connected)),
        authChangesProvider.overrideWithValue(() => auth),
        cloudShadowBreatheProvider.overrideWithValue(() async {}),
      ]);
      await container.read(remoteEditorSnapshotProvider.future);
    });

    tearDown(() async {
      if (container.read(libraryStoreProvider) case LibraryStoreReady()) {
        if (container.read(cloudShadowProvider)
            case CloudShadowRunning(:final shadow)) {
          container.read(cloudShadowProvider.notifier)
            ..cutoff()
            ..detach();
          await shadow.idle;
        }
        await container.read(libraryStoreProvider.notifier).close();
      }
      container.dispose();
      await directory.delete(recursive: true);
    });

    test(
        'the page list is watched only while the editor has the strategy '
        'open', () async {
      await begin();
      expect(lists.controllers, isEmpty);
      editor.open(strategyId);
      await _settled();
      expect(lists.controllers, hasLength(1));

      editor.open(null);
      await _settled();
      expect(lists.controllers.single.hasListener, isFalse);
    });

    test('nothing is taken before the first sign-in', () async {
      auth = (changes: 0, authenticated: false);
      final shadow = await begin();
      deliverPage(pageSnapshot(serverRows()));
      await _settled();

      expect(shadow.ledger, isEmpty);
    });

    test(
        'a page answered on a new connection opens its session before it is '
        'recorded', () async {
      final shadow = await opened();
      queue.stamp = 1;
      deliverPage(pageSnapshot(serverRows()));
      await _settled();
      await shadow.idle;

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
        'a page handed over while the connection is down is skipped as '
        'received offline, though the connection is back when the tap is '
        'told', () async {
      final shadow = await opened();
      queue.stamp = null;
      final heard = tap().heard();
      queue.stamp = 1;
      tap().pageArrived(
        strategyId,
        pageSnapshot(serverRows()),
        heard,
        throughShareLink: false,
      );
      await _settled();
      await shadow.idle;

      expect(shadow.ledger, hasLength(3));
      expect(
        shadow.ledger.last.verdict,
        isA<Skipped>().having(
          (skipped) => skipped.reason,
          'reason',
          SkipReason.receivedOffline,
        ),
      );
    });

    test(
        'any change of sign-in ends the shadow for good, and nothing after it '
        'is recorded', () async {
      final shadow = await opened();
      final recorded = shadow.ledger.length;
      auth = (changes: 2, authenticated: false);
      deliverPage(pageSnapshot(serverRows()));
      auth = (changes: 3, authenticated: true);
      deliverPage(pageSnapshot(serverRows()));
      await _settled();

      expect(shadow.ended, 'the account changed');
      expect(shadow.stopped, isNull);
      expect(shadow.ledger, hasLength(recorded));
      expect(lists.controllers.single.hasListener, isFalse);
    });

    test(
        'a page read through a share link, and a failed page list read, are '
        'counted and not taken', () async {
      final shadow = await opened();
      final recorded = shadow.ledger.length;
      deliverPage(pageSnapshot(serverRows()), throughShareLink: true);
      lists.controllers.single.addError(StateError('the watch broke'));
      await _settled();

      expect(shadow.ledger, hasLength(recorded));
      expect(container.read(cloudShadowProvider.notifier).notTaken, {
        'read through a share link': 1,
        'a page list read failed': 1,
      });
    });

    test('a tap failure stops the shadow', () async {
      final shadow = await begin();
      tap().tapFailed(StateError('the tap broke'));
      expect(shadow.stopped, contains('the tap broke'));
    });

    test('after the cutoff nothing more is taken, and what came is counted',
        () async {
      final shadow = await opened();
      final before = shadow.ledger.length;

      container.read(cloudShadowProvider.notifier).cutoff();
      deliverPage(pageSnapshot(serverRows()));
      await _settled();

      expect(shadow.ledger, hasLength(before));
      expect(container.read(cloudShadowProvider.notifier).notTaken, {
        'handed over after the shadow stopped taking results': 1,
      });
    });

    test('a connection lost after the cutoff is not recorded', () async {
      final shadow = await opened();

      container.read(cloudShadowProvider.notifier).cutoff();
      container.read(_connected.notifier).state = false;
      await _settled();

      expect(shadow.reports.whereType<ShadowConnectionLost>(), isEmpty);
    });

    test(
        'a watch that never closes is counted at the deadline, and one that '
        'fails later still stops the shadow', () async {
      final closing = Completer<void>();
      lists.onCancel = () => closing.future;
      final shadow = await opened();
      final notifier = container.read(cloudShadowProvider.notifier)..cutoff();

      final drained = await notifier.drained(
        DateTime.now().add(const Duration(milliseconds: 200)),
      );
      expect(drained.watchesOpen, 1);

      closing.completeError(StateError('the cancel broke'));
      await _settled();
      expect(shadow.stopped, contains('the cancel broke'));
    });

    test('a run that ends while the store is opening leaves nothing installed',
        () async {
      final opening = Completer<LibraryStoreOpened>();
      final notifier = container.read(cloudShadowProvider.notifier);
      final began = notifier.begin(opening: opening.future, build: 'b');
      notifier.cutoff();
      opening.complete(
        await container
            .read(libraryStoreProvider.notifier)
            .open(file, build: 'b'),
      );
      await began;

      expect(container.read(cloudShadowProvider), isA<CloudShadowFailed>());
      expect(repository.tap, isNull);
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
      Future<void> closeStore() =>
          container.read(libraryStoreProvider.notifier).close();

      List<String> problems(List<CloudStoreLine> lines) => [
            for (final line in lines)
              if (line.problem) line.text,
          ];

      test('reads the store back from disk and compares each strategy',
          () async {
        await opened();
        final log = CloudStoreLog();

        expect(
          problems(await log.end(container, lastStep: DateTime.now())),
          isEmpty,
        );
        await closeStore();
        final readBack = await log.readBack(container);
        expect(problems(readBack), isEmpty);
        expect(readBack.single.text, contains('$strategyId equal, whole'));
      });

      test('an empty store file is not equal', () async {
        await opened();
        final log = CloudStoreLog();
        await log.end(container, lastStep: DateTime.now());
        await closeStore();
        for (final entry in directory.listSync()) {
          entry.deleteSync();
        }

        expect(
          problems(await log.readBack(container)),
          contains(contains('the store does not hold the strategy')),
        );
      });

      test(
          'a run that recorded no strategy fails its read back, and a page '
          'whose page list never came is counted, not judged', () async {
        await begin();
        deliverPage(pageSnapshot(serverRows()));
        await _settled();
        final log = CloudStoreLog();
        final verdict = await log.end(container, lastStep: DateTime.now());
        await closeStore();

        expect(problems(verdict), isEmpty);
        expect(
          verdict.map((line) => line.text),
          contains(
            'CLOUDSTORE counted, not judged: 1 pages handed to the editor, '
            '0 recorded by the shadow, 1 never recorded: they waited for a '
            'page list',
          ),
        );
        expect(
          problems(await log.readBack(container)),
          contains('CLOUDSTORE read back had no strategy to compare'),
        );
      });

      test(
          'the counts name what was handed over, recorded, skipped and not '
          'taken, and judge none of it', () async {
        await opened();
        queue.stamp = null;
        deliverPage(pageSnapshot(serverRows()));
        deliverPage(pageSnapshot(serverRows()), throughShareLink: true);
        await _settled();
        final lines = await CloudStoreLog().end(
          container,
          lastStep: DateTime.now(),
        );

        expect(problems(lines), isEmpty);
        expect(
          lines.map((line) => line.text),
          contains(
            'CLOUDSTORE counted, not judged: 3 pages handed to the editor, '
            '1 recorded by the shadow, 1 skipped: received while the app '
            'counted itself offline, 1 not taken: read through a share link',
          ),
        );
      });

      group('the deadline is one clock from the last step', () {
        late Completer<void> frame;

        setUp(() {
          frame = Completer<void>();
          container.dispose();
          container = ProviderContainer(overrides: [
            strategyOpQueueProvider.overrideWith(() => queue = _Queue()),
            remoteEditorSnapshotProvider.overrideWith(() => editor = _Editor()),
            convexStrategyRepositoryProvider.overrideWithValue(repository),
            convexConnectionSnapshotProvider
                .overrideWith((ref) => ref.watch(_connected)),
            authChangesProvider.overrideWithValue(() => auth),
            cloudShadowBreatheProvider.overrideWithValue(() => frame.future),
          ]);
        });

        Future<List<String>> endWithPicturesLater(Duration shadowDone) async {
          final shadow = await begin();
          deliverPage(pageSnapshot(serverRows()));
          await _settled();
          expect(shadow.ledger, hasLength(1));
          final log = CloudStoreLog(
            finalWait: const Duration(milliseconds: 300),
          );
          final ending = log.end(container, lastStep: DateTime.now());
          unawaited(Future<void>.delayed(shadowDone, frame.complete));
          return [
            for (final line in await Future.delayed(
              const Duration(milliseconds: 600),
              () => ending,
            ))
              if (line.problem) line.text,
          ];
        }

        test(
            'a shadow that finished in time passes, though the picture '
            'watches finish later', () async {
          final found = await endWithPicturesLater(
            const Duration(milliseconds: 100),
          );
          expect(
            found,
            isNot(contains(startsWith('CLOUDSTORE the shadow had work left'))),
          );
        });

        test(
            'a shadow that finished only after the deadline fails, though '
            'it was done before the picture watches', () async {
          final found = await endWithPicturesLater(
            const Duration(milliseconds: 450),
          );
          expect(
            found,
            contains(startsWith('CLOUDSTORE the shadow had work left')),
          );
        });
      });
    });
  });
}
