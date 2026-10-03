import 'dart:convert';
import 'dart:io';

import 'package:icarus_convex_client_gauntlet/contract_gate.dart';
import 'package:test/test.dart';

void main() {
  test('strict Icarus wrapper repairs the Dartvex contract gate', () async {
    final result = await evaluateContractGate();
    final report = result.report;
    final checks = (report['checks']! as List<Object?>)
        .cast<Map<String, Object?>>();

    Map<String, Object?> check(String id) =>
        checks.singleWhere((item) => item['id'] == id);

    expect(check('function_rename')['status'], 'pass');
    expect(check('argument_rename')['status'], 'pass');
    expect(check('result_field_rename')['status'], 'pass');
    expect(check('result_field_rename')['generatedReturnType'], 'typed');
    expect(check('result_field_rename')['analysisExitCode'], isNonZero);
    expect(check('missing_return_schema')['status'], 'pass');
    expect(
      check('missing_return_schema')['diagnostics'],
      contains(contains('listForParent has an unexpected dynamic result')),
    );
    expect(check('unsupported_validator')['status'], 'pass');
    expect(check('unsupported_validator')['rawGenerationExitCode'], 0);
    expect(check('unsupported_validator')['generationExitCode'], isNonZero);
    expect(
      check('unsupported_validator')['diagnostics'],
      contains(
        contains('folders.js:listForParent → returns → field "futureField"'),
      ),
    );
    expect(check('deterministic_regeneration')['status'], 'pass');
    expect(
      check('deterministic_regeneration')['secondSha256'],
      check('deterministic_regeneration')['firstSha256'],
    );
    expect(report['gatePassed'], isTrue);
    expect(report['decision'], 'continue_runtime_gauntlet');
  });

  test('result mutation changes only the returned public id field', () {
    Map<String, Object?> functionFrom(String fixtureName) {
      final fixture =
          jsonDecode(File('fixtures/$fixtureName').readAsStringSync())
              as Map<String, Object?>;
      return (fixture['functions']! as List<Object?>).single
          as Map<String, Object?>;
    }

    Map<String, Object?> resultFields(Map<String, Object?> function) {
      final returns = function['returns']! as Map<String, Object?>;
      final item = returns['value']! as Map<String, Object?>;
      return Map<String, Object?>.from(item['value']! as Map<String, Object?>);
    }

    final baseline = functionFrom('folders_list_for_parent.json');
    final renamed = functionFrom('folders_result_renamed.json');
    expect(renamed['identifier'], baseline['identifier']);
    expect(renamed['functionType'], baseline['functionType']);
    expect(renamed['visibility'], baseline['visibility']);
    expect(renamed['args'], baseline['args']);

    final baselineFields = resultFields(baseline);
    final renamedFields = resultFields(renamed);
    expect(
      renamedFields.remove('folderPublicId'),
      baselineFields.remove('publicId'),
    );
    expect(renamedFields, baselineFields);
  });
}
