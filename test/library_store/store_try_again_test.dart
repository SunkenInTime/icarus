@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_migration_start.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/store_startup.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/folder_content.dart';
import 'package:icarus/widgets/strategy_tile/strategy_tile.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../library_rows/generated_strategies.dart';
import 'gated_engine.dart';
import 'sender_world.dart' show FakeServer, ReadCall, World;
import 'server_fixtures.dart' show serverRows, servedAccount, strategyId;
import 'unit_harness.dart';

StrategyData _strategy(String id) => StrategyMigrator.migrateToCurrentVersion(
      generatedStrategy(Optionals.unset)
          .copyWith(id: id, name: 'Strategy ${id.toUpperCase()}'),
    );

Future<void> _until(String what, bool Function() done) async {
  for (var waited = 0; !done(); waited++) {
    if (waited == 5000) fail('waited too long for $what');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

List<String> _lossReports() => [
      for (final entry in appProviderContainer.read(inAppDebugProvider))
        if (entry.source == 'libraryStore.lostAnswer') entry.message,
    ];

final class _Counted {
  int opens = 0;
  int served = 0;

  void Function() get serve => () => served++;
}

final class _NotLeased implements StorageEngine {
  const _NotLeased(this.leasing);

  final Leasing leasing;

  @override
  Future<Leasing> lease() async => leasing;
}

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

List<Override> _sendingTo(FakeServer server) => [
      storeBatchSendProvider.overrideWithValue(server.send),
      convexSignInsProvider.overrideWithValue(const Stream.empty()),
      storeReadsProvider.overrideWithValue(server.reads),
      storeGenerationProvider.overrideWithValue(server.generation),
      senderEditorProvider.overrideWithValue(Provider<String?>((ref) => null)),
      senderSignInWatchProvider
          .overrideWithValue(Provider<Object?>((ref) => null)),
      senderConnectionProvider.overrideWithValue(() => 1),
      convexConnectionSnapshotProvider.overrideWith((ref) => true),
      authChangesProvider.overrideWithValue(
        () => (changes: 1, authenticated: true, subject: 'account-a'),
      ),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => appProviderContainer = ProviderContainer());
  late Directory directory;
  late CommitGate gate;
  late ProviderContainer container;
  late _Counted counted;
  late Leasing? firstLease;
  late FakeServer server;

  setUp(() async {
    directory = await openUnitHive();
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put('a', _strategy('a'));
    gate = CommitGate();
    final counts = counted = _Counted();
    firstLease = null;
    server = FakeServer()
      ..owners[strategyId] = servedAccount
      ..rows[strategyId] = serverRows()
      ..connection = 1
      ..clock = DateTime.now;
    appProviderContainer.read(inAppDebugProvider.notifier).clearLogs();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_SignedOut.new),
        libraryStoreProvider.overrideWith(
          () => LibraryStoreNotifier(
            wrapEngine: (engine) => switch ((++counts.opens, firstLease)) {
              (1, final refused?) => _NotLeased(refused),
              _ => GatedEngine(engine, gate),
            },
          ),
        ),
        ..._sendingTo(server),
      ],
    );
  });
  tearDown(() async {
    gate.release();
    await container.read(libraryStoreProvider.notifier).close();
    container.dispose();
    LocalLibrary.source = const LibraryInHive();
    await closeUnitHive();
  });

  LibraryStoreNotifier notifier() =>
      container.read(libraryStoreProvider.notifier);

  LibraryStore store() => switch (container.read(libraryStoreProvider)) {
        LibraryStoreReady(:final store) => store,
        final other => fail('$other'),
      };

  LibraryOnStore? onStore() => container.read(libraryOnStoreProvider);

  List<String> shown() =>
      [for (final s in const LocalLibrary().storedStrategies) s.id];

  LibraryStoreLaunch launch(List<String> flags) =>
      LibraryStoreLaunch.parse(flags, mayShadow: true);

  Future<void> open({bool cloud = false}) async {
    final opening = await openLibraryOnStore(
      container,
      launch([
        LibraryStoreLaunch.storeFlag,
        if (cloud) LibraryStoreLaunch.cloudSendFlag,
      ]),
      hiveDirectory: directory.path,
      allowsLocalLibrary: true,
      build: 'b',
      bringUpToDate: () async {},
      servedAgain: counted.serve,
      firstFrame: Future.value(),
    );
    expect(onStore(), isA<LibraryServedFromStore>());
    if (cloud) {
      beginCloudSender(
        container,
        (opening: opening, cloudSends: true),
        build: 'b',
      );
      await _until(
        'the sender',
        () => container.read(cloudSenderProvider) != null,
      );
    }
  }

  Future<LibraryNotServed> loseASave() async {
    gate.doubtNext = true;
    expect(
      await const LocalLibrary().addStrategy(_strategy('lost')),
      isA<LibraryWriteFailed>()
          .having((w) => w.mayHaveLanded, 'mayHaveLanded', isTrue),
    );
    return onStore()! as LibraryNotServed;
  }

  for (final landed in [true, false]) {
    test(
        'a local save whose answer is lost (${landed ? '' : 'not '}landed) '
        'shows the could-not-open face, is reported with its words, and Try '
        'again serves a fresh read', () async {
      await open();
      if (landed) {
        gate.doubtNext = true;
      } else {
        gate.doubtUnlandedNext = true;
      }

      final written = await const LocalLibrary().addStrategy(_strategy('c'));

      expect(
        written,
        isA<LibraryWriteFailed>()
            .having((w) => w.mayHaveLanded, 'mayHaveLanded', isTrue),
      );
      expect(onStore(), isA<LibraryNotServed>());
      expect(LocalLibrary.source, isA<LibraryNotOpened>());
      expect(
        _lossReports(),
        [contains('the change may not have been saved')],
      );

      await (onStore()! as LibraryNotServed).tryAgain();

      expect(onStore(), isA<LibraryServedFromStore>());
      expect(counted.opens, 2);
      expect(counted.served, 1);
      expect(shown(), landed ? ['a', 'c'] : ['a']);
      expect(await const LocalLibrary().addStrategy(_strategy('c')),
          isA<LibraryWritten>());
      expect(shown(), ['a', 'c']);
    });
  }

  test('Try again pressed twice at once opens the store once and serves once',
      () async {
    await open();
    final notServed = await loseASave();

    await Future.wait([notServed.tryAgain(), notServed.tryAgain()]);

    expect(counted.opens, 2);
    expect(counted.served, 1);
    expect(onStore(), isA<LibraryServedFromStore>());
  });

  Future<(LibraryNotServed, LibraryStore, Future<LibraryWrite>)>
      closeHeldByAWrite() async {
    await open();
    final notServed = await loseASave();
    await notServed.tryAgain();
    final held = store();
    gate.hold();
    final commits = gate.commits;
    final writing = const LocalLibrary().addStrategy(_strategy('w'));
    await _until('the held write', () => gate.commits > commits);
    return (notServed, held, writing);
  }

  List<String> statesFrom() {
    final states = <String>[];
    container.listen<LibraryStoreState>(
      libraryStoreProvider,
      (_, next) => states.add(next.runtimeType.toString()),
    );
    return states;
  }

  test(
      'Try again pressed while a close is running shares that close, then '
      'ends served on one open store', () async {
    final (notServed, held, writing) = await closeHeldByAWrite();
    final states = statesFrom();
    final closing = notifier().close();
    final trying = notServed.tryAgain();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(states, isEmpty);

    gate.release();
    await Future.wait([writing, closing, trying]);

    expect(states, [
      'LibraryStoreClosed',
      'LibraryStoreOpening',
      'LibraryStoreReady',
    ]);
    expect(held.isOpen, isFalse);
    expect(store().isOpen, isTrue);
    expect(counted.opens, 3);
    expect(onStore(), isA<LibraryServedFromStore>());
    expect(shown(), ['a', 'lost', 'w']);
  });

  test('an open asked for while a close is running waits for it to finish',
      () async {
    final (_, held, writing) = await closeHeldByAWrite();
    final states = statesFrom();
    final closing = notifier().close();
    final opening = notifier().open(libraryStoreFile(directory.path));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(states, isEmpty);

    gate.release();
    await Future.wait([writing, closing]);

    expect(await opening, isA<LibraryStoreReady>());
    expect(states, [
      'LibraryStoreClosed',
      'LibraryStoreOpening',
      'LibraryStoreReady',
    ]);
    expect(held.isOpen, isFalse);
    expect(store().isOpen, isTrue);
  });

  Future<void> pageShown(CloudSender sender) async {
    final page = serverRows().pages.first.publicId;
    sender
      ..liveOpened(strategyId, ReadOfPage(page))
      ..liveArrived(
        strategyId,
        ReadOfPage(page),
        servedAccount,
        server.answerNow(ReadCall(strategyId, page, servedAccount)),
      );
    for (var waited = 0;; waited++) {
      if (switch (await store().readPage(strategyId, page)) {
        Found(:final value) => value.elements.isNotEmpty,
        _ => false,
      }) {
        break;
      }
      if (waited == 5000) fail('waited too long for the page shown');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    sender.liveClosed(strategyId, ReadOfPage(page));
  }

  Future<void> sentOnce(String opId) async {
    final sender = container.read(cloudSenderProvider)!;
    expect(identical(sender.store.store, store()), isTrue);
    sender.adopt(strategyId);
    await _until('the adoption', () => !sender.adopting(strategyId));
    await pageShown(sender);
    final element = switch (await store().readPage(
      strategyId,
      serverRows().pages.first.publicId,
    )) {
      Found(:final value) => value.elements.whereType<LiveElement>().first,
      final other => fail('$other'),
    };
    final seen = switch (await store().readStrategy(strategyId)) {
      Found(:final value) => value,
      final other => fail('$other'),
    };
    await store().commitAllAs(
      servedAccount,
      strategyId,
      [World.moveOf(element, 1, opId)],
      seen: seen,
    );
    await _until('the op sent', () => server.log.contains('send $opId'));
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(server.log.where((line) => line == 'send $opId'), hasLength(1));
  }

  List<CloudSender> sendersBegun() {
    final begun = <CloudSender>[];
    container.listen(cloudSenderProvider, (_, next) {
      if (next != null && !begun.contains(next)) begun.add(next);
    }, fireImmediately: true);
    return begun;
  }

  for (final (what, refused) in [
    ('held by another instance', const HeldByAnotherWriter() as Leasing),
    (
      'refused for a device fault',
      const LeaseFailed(DeviceFailure('the disk is not ready')) as Leasing,
    ),
  ]) {
    test(
        'a first open $what starts no sender, and Try again starts one on the '
        'store it opened, which sends a pending op once', () async {
      firstLease = refused;
      final begun = sendersBegun();
      final opening = await openLibraryOnStore(
        container,
        launch([LibraryStoreLaunch.storeFlag, LibraryStoreLaunch.cloudSendFlag]),
        hiveDirectory: directory.path,
        allowsLocalLibrary: true,
        build: 'b',
        bringUpToDate: () async {},
        servedAgain: counted.serve,
        firstFrame: Future.value(),
      );
      beginCloudSender(
        container,
        (opening: opening, cloudSends: true),
        build: 'b',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(onStore(), isA<LibraryNotServed>());
      expect(begun, isEmpty);

      await (onStore()! as LibraryNotServed).tryAgain();
      await _until('a sender', () => begun.isNotEmpty);

      expect(onStore(), isA<LibraryServedFromStore>());
      expect(begun, hasLength(1));
      await sentOnce('move-$what');
    });
  }

  test('a first open that is ready starts exactly one sender', () async {
    final begun = sendersBegun();
    await open(cloud: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(begun, hasLength(1));
    expect(identical(begun.single.store.store, store()), isTrue);
  });

  test('the close at exit starts no sender', () async {
    final begun = sendersBegun();
    await open(cloud: true);
    await notifier().close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(libraryStoreProvider), isA<LibraryStoreClosed>());
    expect(begun, hasLength(1));
  });

  test(
      'the cloud sender restarts on the store Try again opened, and an op '
      'whose answer was lost is sent once after it', () async {
    await open(cloud: true);
    final first = container.read(cloudSenderProvider)!;
    first.adopt(strategyId);
    await _until('the adoption', () => !first.adopting(strategyId));
    await pageShown(first);
    final element = switch (await store().readPage(
      strategyId,
      serverRows().pages.first.publicId,
    )) {
      Found(:final value) => value.elements.whereType<LiveElement>().first,
      final other => fail('$other'),
    };
    final seen = switch (await store().readStrategy(strategyId)) {
      Found(:final value) => value,
      final other => fail('$other'),
    };
    gate.doubtNext = true;
    expect(
      await store().commitAllAs(
        servedAccount,
        strategyId,
        [World.moveOf(element, 1, 'move-1')],
        seen: seen,
      ),
      isA<SaveInDoubt<Object?, Object?>>(),
    );
    expect(
      await const LocalLibrary().addStrategy(_strategy('c')),
      isA<LibraryWriteFailed>(),
    );
    expect(server.log, isNot(contains('send move-1')));

    await (onStore()! as LibraryNotServed).tryAgain();
    await _until(
      'the op sent',
      () => server.log.contains('send move-1'),
    );
    await Future<void>.delayed(const Duration(seconds: 2));

    final restarted = container.read(cloudSenderProvider)!;
    expect(identical(restarted, first), isFalse);
    expect(identical(restarted.store.store, store()), isTrue);
    expect(server.log.where((line) => line == 'send move-1'), hasLength(1));
  });

  test(
      'with the library store off and the cloud sender on, a sender write '
      'whose answer is lost leaves the Hive library served', () async {
    final stores = openStores(
      container,
      launch([LibraryStoreLaunch.offFlag, LibraryStoreLaunch.cloudSendFlag]),
      hiveDirectory: directory.path,
      build: 'b',
    );
    beginCloudSender(container, stores, build: 'b');
    await stores.opening;
    await _until(
      'the sender',
      () => container.read(cloudSenderProvider) != null,
    );
    final sender = container.read(cloudSenderProvider)!;
    gate.doubtNext = true;

    sender.adopt(strategyId);
    await _until('the sender to end', () => sender.ended != null);

    expect(store().library, isA<LibraryShut>());
    expect(LocalLibrary.source, isA<LibraryInHive>());
    expect(onStore(), isNull);
    expect(shown(), ['a']);
    expect(_lossReports(), [contains('a cloud write for $strategyId')]);
  });

  testWidgets(
      'the library screen shows its strategies up to a lost answer, then the '
      'could-not-open face, with no empty frame between', (tester) async {
    await tester.runAsync(open);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          themeMode: ThemeMode.dark,
          darkTheme: ShadThemeData(
            brightness: Brightness.dark,
            colorScheme: Settings.tacticalVioletTheme,
          ),
          home: Material(child: FolderContent(onCreateStrategy: () {})),
        ),
      ),
    );
    List<String> tiles() => [
          for (final tile
              in tester.widgetList<StrategyTile>(find.byType(StrategyTile)))
            tile.localStrategy!.id,
        ]..sort();
    final face = find.byKey(const ValueKey('library-not-opened'));
    final empty = find.byKey(const ValueKey('library-empty-state'));
    await tester.pump();
    expect(tiles(), ['a']);

    gate.doubtNext = true;
    late final Future<LibraryWrite> saving;
    await tester.runAsync(() async {
      saving = const LocalLibrary().addStrategy(_strategy('c'));
    });
    await tester.pump();
    expect(tiles(), ['a', 'c']);
    await tester.runAsync(() => saving);

    var faceFrames = 0;
    for (var frame = 0; frame < 30; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      final now = tiles();
      expect(now.isEmpty ? face.evaluate().isNotEmpty : now.length == 2, isTrue,
          reason: 'frame $frame shows $now');
      expect(empty, findsNothing, reason: 'frame $frame');
      if (face.evaluate().isNotEmpty) faceFrames++;
    }

    expect(faceFrames, greaterThan(0));
    expect(tiles(), isEmpty);
    expect(face, findsOneWidget);
  });
}
