import 'dart:convert';
import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

ElementPayload _payload(String kind, Object? data) => ElementPayload(
  kind: ElementKind.named(kind)!,
  payloadVersion: 1,
  data: data! as Map<String, Object?>,
);

void main() {
  final cases =
      jsonDecode(
            File(
              '../../tool/library_parity/cases/field_defaults.json',
            ).readAsStringSync(),
          )
          as List<Object?>;
  for (final entry in cases.cast<Map<String, Object?>>()) {
    final kind = entry['kind']! as String;
    final base = _payload(kind, entry['base']);
    final desired = _payload(kind, entry['desired']);
    final current = _payload(kind, entry['current']);
    test('${entry['name']}: the edit names what changed', () {
      expect(switch (elementEdit(base, desired)) {
        FieldEdit(:final fields) => fields,
        WholeEdit(:final reason) => reason,
      }, entry['fields']);
    });
    test('${entry['name']}: the server would hold the merged payload', () {
      final fields = (entry['fields']! as List<Object?>).cast<String>();
      expect(switch (mergeElementPayload(
        current,
        desired,
        FieldMerge(fields: fields),
      )) {
        Merged(:final value) => value.data,
        final other => other,
      }, entry['merged']);
    });
  }
}
