import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

void main() {
  final asked = [for (var i = 0; i < 250; i += 1) 'image-$i'];

  test('asks about images a bounded batch at a time', () async {
    final transport =
        _ReferencesTransport({'image-3', 'image-120', 'image-249'});
    final repository = ConvexStrategyRepository(IcarusConvexApi(transport));

    final referenced = await repository.fetchReferencedAssetIds(
      'strategy-a',
      [...asked, 'image-3'],
    );

    expect(referenced, {'image-3', 'image-120', 'image-249'});
    expect(transport.batchSizes, [100, 100, 50]);
  });

  test(
      'full snapshots are read as a client that can take one without the '
      "trash's pages", () async {
    final transport = _RecordingTransport();
    final repository = ConvexStrategyRepository(IcarusConvexApi(transport));

    await expectLater(
        repository.fetchFullSnapshot('strategy-a'), throwsStateError);

    final (name, args) = transport.calls.single;
    expect(name, 'strategy:getFullSnapshot');
    expect(args.value['acceptsTrashedPagesLeftOut'], isA<ConvexBoolean>());
    expect((args.value['acceptsTrashedPagesLeftOut'] as ConvexBoolean).value,
        isTrue);
  });

  test("reads and writes as a client that keeps images' picture ids", () async {
    final transport = _RecordingTransport();
    final repository = ConvexStrategyRepository(IcarusConvexApi(transport));

    await expectLater(
        repository.fetchFullSnapshot('strategy-a'), throwsStateError);
    await expectLater(
      repository.fetchPageSnapshot(
        strategyPublicId: 'strategy-a',
        pagePublicId: 'page-1',
      ),
      throwsStateError,
    );
    await expectLater(
      repository.applyBatch(
        strategyPublicId: 'strategy-a',
        clientId: 'client-a',
        ops: const [
          ElementDeleteOp(
            opId: 'op-1',
            pagePublicId: 'page-1',
            elementPublicId: 'image-1',
            expectedElementRevision: 1,
          ),
        ],
      ),
      throwsStateError,
    );

    expect(transport.calls.map((call) => call.$1), [
      'strategy:getFullSnapshot',
      'page:getSnapshot',
      'ops:applyBatch',
    ]);
    for (final (name, args) in transport.calls) {
      expect((args.value['acceptsPictureIds'] as ConvexBoolean?)?.value, isTrue,
          reason: name);
    }
  });

  test('cannot tell if any batch cannot', () async {
    final transport = _ReferencesTransport({'image-3'}, nullBatch: 1);
    final repository = ConvexStrategyRepository(IcarusConvexApi(transport));

    expect(
        await repository.fetchReferencedAssetIds('strategy-a', asked), isNull);
  });
}

/// A server whose content shows [referenced]; the batch numbered [nullBatch]
/// is answered as before the reference backfill.
final class _ReferencesTransport implements ConvexTransport {
  _ReferencesTransport(this.referenced, {this.nullBatch});

  final Set<String> referenced;
  final int? nullBatch;
  final batchSizes = <int>[];

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    expect(name, 'images:listReferencedAssetIds');
    final ids = [
      for (final id in (args.value['assetPublicIds'] as ConvexArray).value)
        (id as ConvexString).value,
    ];
    batchSizes.add(ids.length);
    if (batchSizes.length - 1 == nullBatch) return const ConvexNull();
    return ConvexArray([
      for (final id in ids)
        if (referenced.contains(id)) ConvexString(id),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Records the arguments of each query, then fails it.
final class _RecordingTransport implements ConvexTransport {
  final calls = <(String, ConvexObject)>[];

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    calls.add((name, args));
    throw StateError('not answered in this test');
  }

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async {
    calls.add((name, args));
    throw StateError('not answered in this test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
