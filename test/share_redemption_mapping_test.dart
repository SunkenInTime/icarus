import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';

void main() {
  ConvexObject strategyResult({required String role, bool? alreadyHadAccess}) {
    return ConvexObject({
      'ok': const ConvexBoolean(true),
      'targetType': const ConvexString('strategy'),
      'strategyPublicId': const ConvexString('strategy-1'),
      'folderPublicId': const ConvexNull(),
      'role': ConvexString(role),
      if (alreadyHadAccess != null)
        'alreadyHadAccess': ConvexBoolean(alreadyHadAccess),
    });
  }

  Future<bool> redeem(ConvexObject result) async {
    final repository = ConvexStrategyRepository(
      IcarusConvexApi(_FakeTransport(result)),
    );
    return (await repository.redeemShareLink('ICR-2345-6789-ABCD-EFGH'))
        .alreadyHadAccess;
  }

  test('uses what the server reports', () async {
    expect(await redeem(strategyResult(role: 'viewer', alreadyHadAccess: true)),
        isTrue);
    expect(
        await redeem(strategyResult(role: 'viewer', alreadyHadAccess: false)),
        isFalse);
  });

  test('from a deployment that predates the field, an owner had access',
      () async {
    expect(await redeem(strategyResult(role: 'owner')), isTrue);
    expect(await redeem(strategyResult(role: 'viewer')), isFalse);
  });
}

final class _FakeTransport implements ConvexTransport {
  _FakeTransport(this.result);

  final ConvexValue result;

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) async => result;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
