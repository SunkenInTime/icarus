import 'dart:convert';
import 'dart:io';

import 'package:icarus_convex_codegen/icarus_convex_codegen.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  final packageRoot = Directory.current.absolute;
  final fixtures = Directory(path.join(packageRoot.path, 'test', 'fixtures'));
  final errorCodes = File(path.join(fixtures.path, 'error_codes.json'));

  test(
    'positive fixture maps every supported schema node deterministically',
    () {
      final contract = parseContract(
        functionSpecFile: File(
          path.join(fixtures.path, 'positive_all_nodes.json'),
        ),
        errorCodesFile: errorCodes,
      );
      final first = emitContract(mapContract(contract, const {}));
      final second = emitContract(mapContract(contract, const {}));

      expect(first, equals(second));
      expect(first.keys, {
        'convex_error_codes.dart',
        'convex_models.dart',
        'generated.dart',
        'icarus_convex_api.dart',
      });
      expect(first['convex_models.dart'], contains('Uint8List'));
      expect(first['convex_models.dart'], contains('BigInt'));
      expect(
        first['convex_models.dart'],
        contains('sealed class FixtureAllNodesResult'),
      );
      expect(first['icarus_convex_api.dart'], contains('ConvexQuery<'));
    },
  );

  test('positive fixture generates analyzable standalone libraries', () async {
    final contract = parseContract(
      functionSpecFile: File(
        path.join(fixtures.path, 'positive_all_nodes.json'),
      ),
      errorCodesFile: errorCodes,
    );
    final directory = Directory.systemTemp.createTempSync('icarus-analyze-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final generated = Directory(
      path.join(directory.path, 'lib', 'collab', 'generated'),
    );
    writeGeneratedOutput(
      generated,
      emitContract(mapContract(contract, const {})),
    );
    _writeAnalysisStubs(directory, packageRoot);
    final analysis = await Process.run(Platform.resolvedExecutable, [
      'analyze',
      path.join(directory.path, 'lib'),
    ]);
    expect(
      analysis.exitCode,
      0,
      reason: '${analysis.stdout}${analysis.stderr}',
    );
  });

  test('negative fixtures fail with their golden diagnostic', () {
    final goldenLines = File(
      path.join(packageRoot.path, 'test', 'goldens', 'failures.txt'),
    ).readAsLinesSync();
    for (final line in goldenLines) {
      final separator = line.indexOf('|');
      final fixtureName = line.substring(0, separator);
      final expected = line.substring(separator + 1);
      expect(
        () {
          final contract = parseContract(
            functionSpecFile: File(path.join(fixtures.path, fixtureName)),
            errorCodesFile: errorCodes,
          );
          mapContract(contract, const {});
        },
        throwsA(
          isA<ContractException>().having(
            (error) => error.message,
            fixtureName,
            expected,
          ),
        ),
      );
    }
  });

  test('any is rejected explicitly', () {
    final directory = Directory.systemTemp.createTempSync('icarus-any-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final spec = File(path.join(directory.path, 'spec.json'))
      ..writeAsStringSync(
        jsonEncode(
          _singleFunction(
            args: _object({
              'value': _field({'type': 'any'}),
            }),
            result: {'type': 'null'},
          ),
        ),
      );
    expect(
      () => parseContract(functionSpecFile: spec, errorCodesFile: errorCodes),
      throwsA(
        isA<ContractException>().having(
          (error) => error.message,
          'message',
          contains('uses forbidden validator any'),
        ),
      ),
    );
  });

  test(
    'payload scan resolves generic type and rejects duplicate tags',
    () async {
      final directory = Directory.systemTemp.createTempSync('icarus-codecs-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final valid = File(path.join(directory.path, 'valid.dart'))
        ..writeAsStringSync(_codecSource(secondTag: 'drawing'));
      final bindings = await scanPayloadBindings(valid);
      expect(bindings['agent']?.dartType, 'Map<String, Object?>');
      expect(bindings['drawing']?.codecClass, 'SecondCodec');

      final duplicate = File(path.join(directory.path, 'duplicate.dart'))
        ..writeAsStringSync(_codecSource(secondTag: 'agent'));
      await expectLater(
        scanPayloadBindings(duplicate),
        throwsA(
          isA<ContractException>().having(
            (error) => error.message,
            'message',
            'Duplicate payload binding for tag agent',
          ),
        ),
      );
    },
  );

  test('unbound and unused payload tags fail closed', () {
    final contract = ConvexContract(
      functions: [
        ConvexFunctionContract(
          identifier: 'fixture.js:payload',
          moduleName: 'fixture',
          functionName: 'payload',
          kind: ConvexFunctionKind.query,
          args: const ObjectValidator({}),
          result: _payloadEnvelope('agent'),
        ),
      ],
      errorCodes: const [],
    );
    expect(
      () => mapContract(contract, const {}),
      throwsA(
        isA<ContractException>().having(
          (error) => error.message,
          'message',
          'Missing payload binding for tag agent',
        ),
      ),
    );
    expect(
      () => mapContract(
        const ConvexContract(functions: [], errorCodes: []),
        const {
          'agent': PayloadBinding(
            tag: 'agent',
            codecClass: 'AgentCodec',
            dartType: 'Object',
          ),
        },
      ),
      throwsA(
        isA<ContractException>().having(
          (error) => error.message,
          'message',
          'Unused payload bindings: agent',
        ),
      ),
    );
  });

  test('owned output recreation removes stale files', () {
    final directory = Directory.systemTemp.createTempSync('icarus-output-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File(path.join(directory.path, 'stale.dart'))
      ..createSync()
      ..writeAsStringSync('stale');
    writeGeneratedOutput(directory, const {'current.dart': 'current\n'});
    expect(File(path.join(directory.path, 'stale.dart')).existsSync(), isFalse);
    expect(
      File(path.join(directory.path, 'current.dart')).readAsStringSync(),
      'current\n',
    );
  });

  test('contract mutations change output or stop generation', () {
    final baselineSpec = _mutationSpec();
    final baseline = _emitInMemory(baselineSpec, ['CONFLICT']);

    final mutations = <Map<String, Object?>>[
      _deepCopy(baselineSpec)
        ..['functions'] = [
          ...((baselineSpec['functions'] as List).cast<Map<String, Object?>>())
              .map(
                (function) => {...function, 'identifier': 'sample.js:renamed'},
              ),
        ],
      _renameField(baselineSpec, area: 'args', from: 'name', to: 'title'),
      _renameField(baselineSpec, area: 'returns', from: 'name', to: 'title'),
      _replaceEnumMember(baselineSpec, 'first', 'second'),
    ];
    for (final mutation in mutations) {
      expect(_emitInMemory(mutation, ['CONFLICT']), isNot(equals(baseline)));
    }
    expect(_emitInMemory(baselineSpec, ['FORBIDDEN']), isNot(equals(baseline)));
  });

  test('breaking mutations fail an unchanged typed caller', () async {
    final directory = Directory.systemTemp.createTempSync('icarus-caller-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final generated = Directory(
      path.join(directory.path, 'lib', 'collab', 'generated'),
    );
    _writeAnalysisStubs(directory, packageRoot);
    final caller = File(path.join(directory.path, 'bin', 'caller.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
import '../lib/collab/generated/generated.dart';

Future<String> unchangedCaller(IcarusConvexApi api) async {
  final result = await api.sample
      .read(name: 'name', mode: SampleReadArgsMode.first)
      .fetch();
  if (ConvexErrorCode.conflict.wireName.isEmpty) throw StateError('code');
  return result.name;
}
''');

    Future<ProcessResult> analyzeWith(
      Map<String, Object?> spec,
      List<String> codes,
    ) async {
      writeGeneratedOutput(generated, _emitInMemory(spec, codes));
      return Process.run(Platform.resolvedExecutable, [
        'analyze',
        caller.path,
        generated.path,
      ]);
    }

    final baselineSpec = _mutationSpec();
    final baseline = await analyzeWith(baselineSpec, ['CONFLICT']);
    expect(
      baseline.exitCode,
      0,
      reason: '${baseline.stdout}${baseline.stderr}',
    );

    final mutations = <({Map<String, Object?> spec, List<String> codes})>[
      (
        spec: _deepCopy(baselineSpec)
          ..['functions'] = [
            ...((baselineSpec['functions'] as List)
                    .cast<Map<String, Object?>>())
                .map(
                  (function) => {
                    ...function,
                    'identifier': 'sample.js:renamed',
                  },
                ),
          ],
        codes: ['CONFLICT'],
      ),
      (
        spec: _renameField(
          baselineSpec,
          area: 'args',
          from: 'name',
          to: 'title',
        ),
        codes: ['CONFLICT'],
      ),
      (
        spec: _renameField(
          baselineSpec,
          area: 'returns',
          from: 'name',
          to: 'title',
        ),
        codes: ['CONFLICT'],
      ),
      (
        spec: _replaceEnumMember(baselineSpec, 'first', 'second'),
        codes: ['CONFLICT'],
      ),
      (spec: baselineSpec, codes: ['FORBIDDEN']),
    ];
    for (final mutation in mutations) {
      final result = await analyzeWith(mutation.spec, mutation.codes);
      expect(
        result.exitCode,
        isNot(0),
        reason: 'Mutation unexpectedly preserved the caller:\n${result.stdout}',
      );
    }
  });
}

void _writeAnalysisStubs(Directory directory, Directory packageRoot) {
  final transport = File(
    path.join(
      directory.path,
      'lib',
      'collab',
      'transport',
      'convex_transport.dart',
    ),
  )..createSync(recursive: true);
  transport.writeAsStringSync(
    File(
      path.normalize(
        path.join(
          packageRoot.path,
          '..',
          '..',
          'lib',
          'collab',
          'transport',
          'convex_transport.dart',
        ),
      ),
    ).readAsStringSync(),
  );
  File(path.join(directory.path, 'lib', 'collab', 'convex_payload_codecs.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('// No opaque payloads in this fixture.\n');
}

Map<String, String> _emitInMemory(
  Map<String, Object?> spec,
  List<String> codes,
) {
  final directory = Directory.systemTemp.createTempSync('icarus-mutation-');
  try {
    final specFile = File(path.join(directory.path, 'spec.json'))
      ..writeAsStringSync(jsonEncode(spec));
    final codesFile = File(path.join(directory.path, 'codes.json'))
      ..writeAsStringSync(jsonEncode(codes));
    return emitContract(
      mapContract(
        parseContract(functionSpecFile: specFile, errorCodesFile: codesFile),
        const {},
      ),
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
}

Map<String, Object?> _mutationSpec() => _singleFunction(
  identifier: 'sample.js:read',
  args: _object({
    'mode': _field({
      'type': 'union',
      'value': [
        {'type': 'literal', 'value': 'first'},
        {'type': 'literal', 'value': 'last'},
      ],
    }),
    'name': _field({'type': 'string'}),
  }),
  result: _object({
    'name': _field({'type': 'string'}),
  }),
);

Map<String, Object?> _renameField(
  Map<String, Object?> source, {
  required String area,
  required String from,
  required String to,
}) {
  final copy = _deepCopy(source);
  final function = ((copy['functions'] as List).single as Map<String, Object?>);
  final validator = function[area] as Map<String, Object?>;
  final fields = validator['value'] as Map<String, Object?>;
  fields[to] = fields.remove(from);
  return copy;
}

Map<String, Object?> _replaceEnumMember(
  Map<String, Object?> source,
  String from,
  String to,
) {
  final copy = _deepCopy(source);
  final function = ((copy['functions'] as List).single as Map<String, Object?>);
  final args = function['args'] as Map<String, Object?>;
  final mode =
      ((args['value'] as Map<String, Object?>)['mode']
              as Map<String, Object?>)['fieldType']
          as Map<String, Object?>;
  final members = mode['value'] as List;
  for (final member in members.cast<Map<String, Object?>>()) {
    if (member['value'] == from) member['value'] = to;
  }
  return copy;
}

Map<String, Object?> _deepCopy(Map<String, Object?> source) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(source)) as Map);

Map<String, Object?> _singleFunction({
  String identifier = 'fixture.js:test',
  required Map<String, Object?> args,
  required Map<String, Object?> result,
}) => {
  'functions': [
    {
      'args': args,
      'functionType': 'Query',
      'identifier': identifier,
      'returns': result,
      'visibility': {'kind': 'public'},
    },
  ],
};

Map<String, Object?> _object(Map<String, Object?> fields) => {
  'type': 'object',
  'value': fields,
};

Map<String, Object?> _field(Map<String, Object?> validator) => {
  'fieldType': validator,
  'optional': false,
};

ObjectValidator _payloadEnvelope(String tag) => ObjectValidator({
  'kind': ObjectField(validator: LiteralValidator(tag), optional: false),
  'payloadVersion': const ObjectField(
    validator: NumberValidator(),
    optional: false,
  ),
  'data': const ObjectField(
    validator: RecordValidator(
      keys: StringValidator(),
      values: StringValidator(),
    ),
    optional: false,
  ),
});

String _codecSource({required String secondTag}) =>
    '''
class ConvexPayload {
  const ConvexPayload(this.tag);
  final String tag;
}
abstract interface class ConvexPayloadCodec<T> {}
@ConvexPayload('agent')
final class AgentCodec implements ConvexPayloadCodec<Map<String, Object?>> {}
@ConvexPayload('$secondTag')
final class SecondCodec implements ConvexPayloadCodec<Map<String, Object?>> {}
''';
