import 'dart:io';

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
import 'package:icarus/const/settings.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/services/cloud_library_action.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

void main() {
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
    test('an image this device has not uploaded yet holds the duplicate',
        () async {
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
            state: CloudMediaJobState.pendingUpload,
            attempts: 0,
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
        "This strategy has images that haven't finished uploading. "
            "Duplicate it once it's synced.",
      ]);
    });
  });

  group('local duplicate', () {
    late Directory hiveDir;

    setUp(() async {
      hiveDir = await Directory.systemTemp.createTemp('duplicate_test');
      Hive.init(hiveDir.path);
      registerIcarusAdapters(Hive);
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
  });
}

ProviderContainer _container(
  _RecordingTransport transport,
  List<String> messages, {
  List<CloudMediaUploadJob> unsentImages = const [],
}) {
  return ProviderContainer(overrides: [
    cloudMediaUploadQueueProvider.overrideWith(() => _Queue(unsentImages)),
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
  Future<RemoteStrategyShell> fetchShell(String strategyPublicId) async =>
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
