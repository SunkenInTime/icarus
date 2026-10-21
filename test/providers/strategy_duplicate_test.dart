import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/strategy/strategy_import_export.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:path/path.dart' as path;
import 'package:supabase_flutter/supabase_flutter.dart' show User;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('cloud duplicate', () {
    test('asks the server for the whole copy in one mutation', () async {
      final transport = _RecordingTransport();
      final messages = <String>[];
      final container = _container(transport, messages);
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'source-strategy',
            source: StrategySource.cloud,
          );

      expect(transport.mutations, hasLength(1));
      final (name, args) = transport.mutations.single;
      expect(name, 'strategies:duplicate');
      expect(args['sourceStrategyPublicId'], 'source-strategy');
      expect(args['name'], 'A site execute (Copy)');
      expect(args['folderPublicId'], 'current-folder');
      expect(args['publicId'], isA<String>());
      expect(args['publicId'], isNot('source-strategy'));
      expect(messages, isEmpty);
      expect(transport.libraryListBuilds, 1, reason: 'the library refreshes');
    });

    test(
        'an old server without the mutation shows a message and sends nothing else',
        () async {
      final transport = _RecordingTransport(
        mutationError: const ConvexTransportError(
          rawCode: 'Server Error',
          message: "Could not find public function for 'strategies:duplicate'",
        ),
      );
      final messages = <String>[];
      final container = _container(transport, messages);
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'source-strategy',
            source: StrategySource.cloud,
          );

      expect(transport.mutations.map((call) => call.$1), [
        'strategies:duplicate',
      ]);
      expect(messages, ["Couldn't duplicate this strategy. Try again."]);
      expect(transport.libraryListBuilds, 0);
    });
    test('a strategy too large to copy says so instead of asking to retry',
        () async {
      final transport = _RecordingTransport(
        mutationError: const ConvexTransportError(
          rawCode: 'STRATEGY_TOO_LARGE_TO_DUPLICATE',
          message: 'This strategy is too large to duplicate.',
        ),
      );
      final messages = <String>[];
      final container = _container(transport, messages);
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'source-strategy',
            source: StrategySource.cloud,
          );

      expect(transport.mutations.map((call) => call.$1), [
        'strategies:duplicate',
      ]);
      expect(messages, ['This strategy is too large to duplicate.']);
      expect(transport.libraryListBuilds, 0);
    });

    test('waits for an edit still on its way, then copies', () async {
      final transport = _RecordingTransport();
      final messages = <String>[];
      final ops = _Ops(_unsent(queued: 1));
      final container = _container(transport, messages, ops: ops);
      addTearDown(container.dispose);

      final duplicating =
          container.read(strategyProvider.notifier).duplicateStrategy(
                'source-strategy',
                source: StrategySource.cloud,
              );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // The server copies what it has, so nothing is asked of it yet.
      expect(transport.mutations, isEmpty);
      ops.land();
      await duplicating;

      expect(transport.mutations.map((call) => call.$1), [
        'strategies:duplicate',
      ]);
      expect(messages, isEmpty);
    });

    test('an edit held for review refuses the copy and says why', () async {
      final transport = _RecordingTransport();
      final messages = <String>[];
      final container = _container(
        transport,
        messages,
        ops: _Ops(_unsent(paused: 1)),
      );
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'source-strategy',
            source: StrategySource.cloud,
          );

      expect(transport.mutations, isEmpty);
      expect(messages, [
        "Some changes to this strategy haven't synced yet, so it wasn't "
            'duplicated. Let them sync, or review them, then try again.',
      ]);
    });

    test('another account signing in mid-wait makes no copy', () async {
      final transport = _RecordingTransport();
      final messages = <String>[];
      final ops = _Ops(_unsent(queued: 1));
      final auth = _Auth();
      final container = _container(transport, messages, ops: ops, auth: auth);
      addTearDown(container.dispose);

      final duplicating =
          container.read(strategyProvider.notifier).duplicateStrategy(
                'source-strategy',
                source: StrategySource.cloud,
              );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // The first account's edit is still unsent; the second one's queue,
      // now on show, is empty.
      auth.signInAs('account-b');
      ops.land();
      await duplicating;

      expect(transport.mutations, isEmpty);
      expect(messages, hasLength(1));
    });

    test("another strategy's unsent edit does not hold this copy", () async {
      final transport = _RecordingTransport();
      final container = _container(
        transport,
        <String>[],
        ops: _Ops(_unsent(queued: 1, strategyId: 'other-strategy')),
      );
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'source-strategy',
            source: StrategySource.cloud,
          );

      expect(transport.mutations, hasLength(1));
    });

    test('an image that failed to upload refuses the copy', () async {
      final transport = _RecordingTransport();
      final messages = <String>[];
      final container = _container(
        transport,
        messages,
        unsentImages: [
          CloudMediaUploadJob(
            jobId: 'job-1',
            accountId: 'account-1',
            strategyPublicId: 'source-strategy',
            assetPublicId: 'image-1',
            fileExtension: '.png',
            mimeType: 'image/png',
            state: CloudMediaJobState.failed,
            attempts: 3,
            updatedAt: DateTime.utc(2026),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'source-strategy',
            source: StrategySource.cloud,
          );

      expect(transport.mutations, isEmpty);
      expect(messages, [
        "Some changes to this strategy haven't synced yet, so it wasn't "
            'duplicated. Let them sync, or review them, then try again.',
      ]);
    });
  });

  group('local duplicate', () {
    late Directory hiveDir;

    setUp(() async {
      hiveDir = await Directory.systemTemp.createTemp('duplicate_test');
      Hive.init(hiveDir.path);
      if (!Hive.isAdapterRegistered(20)) registerIcarusAdapters(Hive);
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    });

    tearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });

    test('stays on this device and never calls the server', () async {
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      await box.put(
        'local-strategy',
        StrategyData(
          id: 'local-strategy',
          name: 'Bind B split',
          mapData: MapValue.bind,
          versionNumber: Settings.versionNumber,
          lastEdited: DateTime.utc(2026),
          folderID: 'local-folder',
          pages: const [],
        ),
      );
      final transport = _RecordingTransport();
      final container = _container(transport, <String>[]);
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'local-strategy',
            source: StrategySource.local,
          );

      final copy = box.values.singleWhere((s) => s.id != 'local-strategy');
      expect(copy.name, 'Bind B split (Copy)');
      expect(copy.folderID, 'local-folder');
      expect(copy.mapData, MapValue.bind);
      expect(transport.queries, isEmpty);
      expect(transport.mutations, isEmpty);
    });

    test('gives the copy its own image files, which outlive the original',
        () async {
      // Images are files in each strategy's folder under the support
      // directory; point it into this test's folder.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProvider, (_) async => hiveDir.path);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProvider, null));
      // Export reads the strategy's theme.
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      final pictureBytes = Uint8List.fromList(List.generate(64, (i) => i));
      await PlacedImageProvider.writeImageBytes(
        imageBytes: pictureBytes,
        strategyID: 'local-strategy',
        imageID: 'picture',
        fileExtension: '.png',
      );
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      await box.put(
        'local-strategy',
        StrategyData(
          id: 'local-strategy',
          name: 'Bind B split',
          mapData: MapValue.bind,
          versionNumber: Settings.versionNumber,
          lastEdited: DateTime.utc(2026),
          folderID: null,
          pages: [
            StrategyPage(
              id: 'page',
              name: 'Page 1',
              drawingData: const [],
              agentData: const [],
              abilityData: const [],
              textData: const [],
              imageData: [
                PlacedImage(
                  position: const Offset(100, 100),
                  id: 'picture',
                  aspectRatio: 1,
                  scale: 1,
                  fileExtension: '.png',
                ),
              ],
              utilityData: const [],
              sortIndex: 0,
              isAttack: true,
              settings: StrategySettings(),
            ),
          ],
        ),
      );
      final container = _container(_RecordingTransport(), <String>[]);
      addTearDown(container.dispose);
      final strategies = container.read(strategyProvider.notifier);

      await strategies.duplicateStrategy(
        'local-strategy',
        source: StrategySource.local,
      );
      final copy = box.values.singleWhere((s) => s.id != 'local-strategy');
      await strategies.deleteStrategy(
        'local-strategy',
        source: StrategySource.local,
      );

      final copyPicture = await PlacedImageProvider.getImageFile(
        strategyID: copy.id,
        imageID: copy.pages.single.imageData.single.pictureId,
        fileExtension: '.png',
      );
      expect(await copyPicture.readAsBytes(), pictureBytes);
      final exported = await StrategyImportExportService(container).zipStrategy(
        id: copy.id,
        saveDir: await Directory(path.join(hiveDir.path, 'out')).create(),
      );
      final archive = ZipDecoder().decodeBytes(
        await File(exported).readAsBytes(),
      );
      expect(archive.findFile('picture.png')?.content, pictureBytes);
    });

    test(
        'copies only the pictures the strategy shows, and still copies when '
        'one was already missing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProvider, (_) async => hiveDir.path);
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathProvider, null));
      final pictureBytes = Uint8List.fromList([1, 2, 3]);
      await PlacedImageProvider.writeImageBytes(
        imageBytes: pictureBytes,
        strategyID: 'local-strategy',
        imageID: 'kept',
        fileExtension: '.png',
      );
      final folder = await PlacedImageProvider.getImageFolder('local-strategy');
      await File(path.join(folder.path, 'notes.txt')).writeAsString('stray');
      PlacedImage picture(String id) => PlacedImage(
            position: const Offset(100, 100),
            id: id,
            aspectRatio: 1,
            scale: 1,
            fileExtension: '.png',
          );
      final box = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
      await box.put(
        'local-strategy',
        StrategyData(
          id: 'local-strategy',
          name: 'Bind B split',
          mapData: MapValue.bind,
          versionNumber: Settings.versionNumber,
          lastEdited: DateTime.utc(2026),
          folderID: null,
          pages: [
            StrategyPage(
              id: 'page',
              name: 'Page 1',
              drawingData: const [],
              agentData: const [],
              abilityData: const [],
              textData: const [],
              // "gone" has no file: an older duplicate already lost it.
              imageData: [picture('kept'), picture('gone')],
              utilityData: const [],
              sortIndex: 0,
              isAttack: true,
              settings: StrategySettings(),
            ),
          ],
        ),
      );
      final messages = <String>[];
      final container = _container(_RecordingTransport(), messages);
      addTearDown(container.dispose);

      await container.read(strategyProvider.notifier).duplicateStrategy(
            'local-strategy',
            source: StrategySource.local,
          );

      final copy = box.values.singleWhere((s) => s.id != 'local-strategy');
      expect(copy.pages.single.imageData, hasLength(2));
      final copyFolder = await PlacedImageProvider.getImageFolder(copy.id);
      final copied = copyFolder
          .listSync()
          .map((entity) => path.basename(entity.path))
          .toList();
      expect(copied, ['kept.png']);
      expect(messages, [
        'Duplicated. One picture was already missing from the original, so '
            'the copy is missing it too.',
      ]);
      expect(
        await File(path.join(copyFolder.path, 'kept.png')).readAsBytes(),
        pictureBytes,
      );
    });
  });
}

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

ProviderContainer _container(
  _RecordingTransport transport,
  List<String> messages, {
  List<CloudMediaUploadJob> unsentImages = const [],
  _Ops? ops,
  _Auth? auth,
}) {
  return ProviderContainer(overrides: [
    authProvider.overrideWith(() => auth ?? _Auth()),
    cloudMediaUploadQueueProvider.overrideWith(() => _Queue(unsentImages)),
    strategyOpQueueProvider.overrideWith(
      () => ops ?? _Ops(const StrategyOpQueueState(durableLoaded: true)),
    ),
    cloudStrategiesProvider.overrideWith((ref) {
      transport.libraryListBuilds += 1;
      return const Stream<List<CloudStrategyEntry>>.empty();
    }),
    strategyProvider.overrideWith(_ClosedStrategy.new),
    folderProvider.overrideWith(_CurrentFolder.new),
    convexStrategyRepositoryProvider
        .overrideWithValue(_ShellRepository(transport)),
    cloudLibraryActionReporterProvider.overrideWithValue(
      CloudLibraryActionReporter(
        showMessage: messages.add,
        reportTechnicalFailure: ({
          required source,
          required error,
          required stackTrace,
        }) {},
      ),
    ),
  ]);
}

class _ClosedStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: null,
        strategyName: null,
        source: StrategySource.local,
        isOpen: false,
      );
}

class _Queue extends CloudMediaUploadQueueNotifier {
  _Queue(this.jobs);

  final List<CloudMediaUploadJob> jobs;

  @override
  CloudMediaUploadQueueState build() =>
      CloudMediaUploadQueueState(jobs: jobs, isProcessing: false);
}

/// Signed in as one account, then as [signInAs] says.
class _Auth extends AuthProvider {
  @override
  AppAuthState build() => _signedInAs('account-a');

  void signInAs(String accountId) => state = _signedInAs(accountId);
}

AppAuthState _signedInAs(String accountId) => AppAuthState(
      isLoading: false,
      isAuthenticated: true,
      isConvexUserReady: true,
      convexAuthStatus: ConvexAuthStatus.ready,
      user: User(
        id: accountId,
        appMetadata: const <String, dynamic>{},
        userMetadata: const <String, dynamic>{},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00.000Z',
      ),
    );

/// This device's op queue, set by the test.
class _Ops extends StrategyOpQueueNotifier {
  _Ops(this.initial);

  final StrategyOpQueueState initial;

  @override
  StrategyOpQueueState build() => initial;

  /// Everything this device queued has landed.
  void land() => state = const StrategyOpQueueState(durableLoaded: true);
}

/// Saved work waiting to reach the server for [strategyId].
StrategyOpQueueState _unsent({
  int queued = 0,
  int paused = 0,
  String strategyId = 'source-strategy',
}) =>
    StrategyOpQueueState(
      durableLoaded: true,
      accountOutbox: AccountStrategyOutboxSummary(
        strategies: {
          strategyId: StrategyOutboxSummary(
            strategyPublicId: strategyId,
            queuedCount: queued,
            inFlightCount: 0,
            pausedCount: paused,
            attentionCount: 0,
            successorCount: 0,
          ),
        },
      ),
    );

class _CurrentFolder extends FolderProvider {
  @override
  String? build() => 'current-folder';
}

/// The real repository over a recording transport, so the test sees the
/// exact wire call; only the shell read is canned.
class _ShellRepository extends ConvexStrategyRepository {
  _ShellRepository(_RecordingTransport transport)
      : super(IcarusConvexApi(transport));

  @override
  Future<RemoteStrategyShell> fetchShell(
    String strategyPublicId, {
    String? shareToken,
  }) async =>
      RemoteStrategyShell(
        header: RemoteStrategyHeader(
          publicId: strategyPublicId,
          name: 'A site execute',
          mapData: 'Ascent',
          revision: 3,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        pages: const [],
      );
}

class _RecordingTransport implements ConvexTransport {
  _RecordingTransport({this.mutationError});

  final ConvexTransportError? mutationError;
  final queries = <String>[];

  /// How many times the cloud library list was rebuilt. Kept here so each
  /// test's container has its own count.
  var libraryListBuilds = 0;
  final mutations = <(String, Map<String, Object?>)>[];

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    queries.add(name);
    throw UnimplementedError(name);
  }

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async {
    mutations.add((name, args.toDart()));
    final error = mutationError;
    if (error != null) throw error;
    return ConvexObject({'ok': const ConvexBoolean(true)});
  }

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError(name);

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      throw UnimplementedError(name);
}
