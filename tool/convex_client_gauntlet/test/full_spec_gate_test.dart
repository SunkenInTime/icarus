import 'dart:io';

import 'package:icarus_convex_client_gauntlet/full_spec_gate.dart';
import 'package:test/test.dart';

void main() {
  Future<Map<String, Object?>> gate(String fixture) => evaluateFullSpecGate(
    specFile: File('fixtures/$fixture'),
    scratch: Directory('lib/_full_spec_generated'),
  );

  Map<String, Object?> onlyFunction(Map<String, Object?> report) =>
      (report['functions']! as List<Object?>).single as Map<String, Object?>;

  test('a fully declared result counts as typed', () async {
    final row = onlyFunction(await gate('folders_list_for_parent.json'));
    expect(row['status'], 'typed');
  });

  // Dartvex maps v.any() to dynamic without a warning, inside the record
  // typedef it writes for the result object, so only the declaration scan
  // can catch it.
  test('a nested v.any() result field counts as degraded', () async {
    final row = onlyFunction(await gate('folders_nested_any.json'));
    expect(row['status'], 'degraded');
    expect(
      row['untypedPublicDeclarations'],
      contains(contains('dynamic extra')),
    );
  });
}
