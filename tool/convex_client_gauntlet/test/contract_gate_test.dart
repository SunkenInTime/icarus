import 'package:icarus_convex_client_gauntlet/contract_gate.dart';
import 'package:test/test.dart';

void main() {
  test('Dartvex 0.2.0 fails the declared Icarus contract gate', () async {
    final result = await evaluateContractGate();
    final report = result.report;
    final checks = (report['checks']! as List<Object?>)
        .cast<Map<String, Object?>>();

    Map<String, Object?> check(String id) =>
        checks.singleWhere((item) => item['id'] == id);

    expect(check('function_rename')['status'], 'pass');
    expect(check('argument_rename')['status'], 'pass');
    expect(check('result_field_rename')['status'], 'fail');
    expect(check('result_field_rename')['generatedReturnType'], 'dynamic');
    expect(check('unsupported_validator')['status'], 'fail');
    expect(check('unsupported_validator')['generationExitCode'], 0);
    expect(check('deterministic_regeneration')['status'], 'pass');
    expect(report['gatePassed'], isFalse);
    expect(report['decision'], 'keep_convex_flutter');
  });
}
