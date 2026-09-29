import 'package:flutter_test/flutter_test.dart';
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
