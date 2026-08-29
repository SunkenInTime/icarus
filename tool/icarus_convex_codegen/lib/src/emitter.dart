import 'dart:io';

import 'package:dart_style/dart_style.dart';

import 'contract.dart';
import 'mapper.dart';

final _formatter = DartFormatter(
  languageVersion: DartFormatter.latestLanguageVersion,
);

Map<String, String> emitContract(MappedContract contract) {
  final files = <String, String>{
    'convex_error_codes.dart': _format(_emitErrorCodes(contract.contract)),
    'convex_models.dart': _format(_emitModels(contract)),
    'icarus_convex_api.dart': _format(_emitApi(contract)),
    'generated.dart': _format(_emitBarrel()),
  };
  return Map.unmodifiable(files);
}

void writeGeneratedOutput(Directory output, Map<String, String> files) {
  if (output.existsSync()) output.deleteSync(recursive: true);
  output.createSync(recursive: true);
  final paths = files.keys.toList()..sort();
  for (final path in paths) {
    File('${output.path}/$path').writeAsStringSync(files[path]!);
  }
}

String _format(String source) => _formatter.format(source);

String _header() => '''
// GENERATED CODE - DO NOT MODIFY BY HAND.
// Generated from convex/function_spec.json by tool/icarus_convex_codegen.
// ignore_for_file: prefer_const_constructors, unused_element, unused_import
''';

String _emitBarrel() =>
    '''
${_header()}
export 'convex_error_codes.dart';
export 'convex_models.dart';
export 'icarus_convex_api.dart';
''';

String _emitErrorCodes(ConvexContract contract) {
  final out = StringBuffer()
    ..writeln(_header())
    ..writeln("import '../transport/convex_transport.dart';")
    ..writeln()
    ..writeln('enum ConvexErrorCode {');
  for (final code in contract.errorCodes) {
    out.writeln("  ${lowerCamelCase(code)}('${_escape(code)}'),");
  }
  out
    ..writeln("  unknown('UNKNOWN');")
    ..writeln()
    ..writeln('  const ConvexErrorCode(this.wireName);')
    ..writeln('  final String wireName;')
    ..writeln()
    ..writeln('  static ConvexErrorCode fromWireName(String rawCode) {')
    ..writeln('    for (final code in values) {')
    ..writeln(
      '      if (code != unknown && code.wireName == rawCode) return code;',
    )
    ..writeln('    }')
    ..writeln('    return unknown;')
    ..writeln('  }')
    ..writeln('}')
    ..writeln()
    ..writeln('final class ConvexFunctionException implements Exception {')
    ..writeln('  const ConvexFunctionException({')
    ..writeln('    required this.code,')
    ..writeln('    required this.rawCode,')
    ..writeln('    required this.message,')
    ..writeln('    this.data,')
    ..writeln('  });')
    ..writeln()
    ..writeln('  factory ConvexFunctionException.fromTransport(')
    ..writeln('    ConvexTransportError error,')
    ..writeln('  ) => ConvexFunctionException(')
    ..writeln('    code: ConvexErrorCode.fromWireName(error.rawCode),')
    ..writeln('    rawCode: error.rawCode,')
    ..writeln('    message: error.message,')
    ..writeln('    data: error.data,')
    ..writeln('  );')
    ..writeln()
    ..writeln('  final ConvexErrorCode code;')
    ..writeln('  final String rawCode;')
    ..writeln('  final String message;')
    ..writeln('  final ConvexValue? data;')
    ..writeln()
    ..writeln("  @override String toString() => 'ConvexFunctionException('")
    ..writeln("      '\$rawCode, \$message)';")
    ..writeln('}');
  return out.toString();
}

String _emitModels(MappedContract contract) {
  final out = StringBuffer()
    ..writeln(_header())
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln("import '../convex_payload_codecs.dart';")
    ..writeln("import '../transport/convex_transport.dart';")
    ..writeln()
    ..writeln(_modelRuntime);

  final enums = [...contract.enums]..sort((a, b) => a.name.compareTo(b.name));
  for (final declaration in enums) {
    _emitEnum(out, declaration);
  }

  final unions = [...contract.unions]..sort((a, b) => a.name.compareTo(b.name));
  for (final declaration in unions) {
    _emitUnion(out, declaration);
  }

  final models = [...contract.models]..sort((a, b) => a.name.compareTo(b.name));
  for (final declaration in models) {
    _emitModel(out, declaration);
  }

  final opaqueNames = contract.opaqueUnions.keys.toList()..sort();
  for (final name in opaqueNames) {
    _emitOpaqueUnion(out, name, contract.opaqueUnions[name]!);
  }

  final rawEmitter = _RawPredicateEmitter();
  for (final declaration in contract.rawValidators) {
    rawEmitter.registerRoot(declaration.name, declaration.validator);
  }
  out.writeln(rawEmitter.emit());
  _emitEndpointCodecs(out, contract.functions);
  return out.toString();
}

void _emitEndpointCodecs(StringBuffer out, List<MappedFunction> functions) {
  for (final function in functions) {
    final prefix = _functionPrefix(function);
    out.write('ConvexObject encode${prefix}Args(');
    if (function.argsFields.isNotEmpty) {
      out.write('{');
      for (final field in function.argsFields) {
        if (field.optional) {
          out.write(
            'ConvexOptional<${field.type.dartType}> ${field.dartName} = '
            'const ConvexOptional.absent(),',
          );
        } else {
          out.write('required ${field.type.dartType} ${field.dartName},');
        }
      }
      out.write('}');
    }
    out.writeln(') => ConvexObject({');
    for (final field in function.argsFields) {
      final fieldPath =
          "'${_escape(function.contract.identifier)}.args.${_escape(field.wireName)}'";
      if (field.optional) {
        out.writeln(
          "  if (${field.dartName}.isPresent) '${_escape(field.wireName)}': ${field.type.encode('${field.dartName}.value', fieldPath)},",
        );
      } else {
        out.writeln(
          "  '${_escape(field.wireName)}': ${field.type.encode(field.dartName, fieldPath)},",
        );
      }
    }
    out
      ..writeln('});')
      ..writeln()
      ..writeln(
        '${function.resultType.dartType} decode${prefix}Result(ConvexValue value) =>',
      )
      ..writeln(
        '    ${function.resultType.decode('value', "'${_escape(function.contract.identifier)}.returns'")};',
      )
      ..writeln();
  }
}

void _emitEnum(StringBuffer out, EnumDeclaration declaration) {
  out.writeln('enum ${declaration.name} {');
  for (final value in declaration.values) {
    out.writeln("  ${value.name}('${_escape(value.wireValue)}'),");
  }
  out
    ..writeln('  ;')
    ..writeln()
    ..writeln('  const ${declaration.name}(this.wireName);')
    ..writeln('  final String wireName;')
    ..writeln()
    ..writeln(
      '  static ${declaration.name} fromWireName(String wireName, String path) {',
    )
    ..writeln('    for (final value in values) {')
    ..writeln('      if (value.wireName == wireName) return value;')
    ..writeln('    }')
    ..writeln(
      "    throw ConvexDecodingException(path, 'unknown ${declaration.name} \$wireName');",
    )
    ..writeln('  }')
    ..writeln('}')
    ..writeln();
}

void _emitUnion(StringBuffer out, UnionDeclaration declaration) {
  out
    ..writeln('sealed class ${declaration.name} {')
    ..writeln('  const ${declaration.name}();')
    ..writeln()
    ..writeln(
      '  factory ${declaration.name}.decode(ConvexValue value, String path) {',
    )
    ..writeln('    final object = _decodeObject(value, path);')
    ..writeln('    final discriminator = _decodeString(')
    ..writeln(
      "      object.value['${_escape(declaration.discriminatorName)}'] ?? _missing(path, '${_escape(declaration.discriminatorName)}'),",
    )
    ..writeln("      '\$path.${_escape(declaration.discriminatorName)}',")
    ..writeln('    );')
    ..writeln('    return switch (discriminator) {');
  for (final variant in declaration.variants) {
    out.writeln(
      "      '${_escape(variant.discriminatorValue)}' => ${variant.model.name}.decode(value, path),",
    );
  }
  out
    ..writeln(
      "      _ => throw ConvexDecodingException(path, 'unknown discriminator \$discriminator'),",
    )
    ..writeln('    };')
    ..writeln('  }')
    ..writeln()
    ..writeln('  ConvexObject encode(String path);')
    ..writeln('}')
    ..writeln();
}

void _emitModel(StringBuffer out, ModelDeclaration declaration) {
  final inheritance = declaration.baseName == null
      ? ''
      : ' extends ${declaration.baseName}';
  out
    ..writeln('final class ${declaration.name}$inheritance {')
    ..write('  const ${declaration.name}({');
  for (final field in declaration.fields.where((field) => !field.optional)) {
    out.write('required this.${field.dartName},');
  }
  for (final field in declaration.fields.where((field) => field.optional)) {
    out.write('this.${field.dartName} = const ConvexOptional.absent(),');
  }
  out.writeln('});');
  for (final field in declaration.fields) {
    final type = field.optional
        ? 'ConvexOptional<${field.type.dartType}>'
        : field.type.dartType;
    out.writeln('  final $type ${field.dartName};');
  }
  out
    ..writeln()
    ..writeln(
      '  factory ${declaration.name}.decode(ConvexValue value, String path) {',
    )
    ..writeln('    final object = _decodeObject(value, path);')
    ..writeln('    _checkObjectFields(object, path, const {');
  if (declaration.discriminatorName != null) {
    out.writeln("      '${_escape(declaration.discriminatorName!)}',");
  }
  for (final field in declaration.fields) {
    out.writeln("      '${_escape(field.wireName)}',");
  }
  out
    ..writeln('    });')
    ..writeln('    return ${declaration.name}(');
  for (final field in declaration.fields) {
    final wire = _escape(field.wireName);
    final fieldPath = "'\$path.$wire'";
    if (field.optional) {
      out
        ..writeln(
          '      ${field.dartName}: object.value.containsKey(\'$wire\')',
        )
        ..writeln('          ? ConvexOptional.present(')
        ..writeln(
          '              ${field.type.decode("object.value['$wire']!", fieldPath)},',
        )
        ..writeln('            )')
        ..writeln('          : const ConvexOptional.absent(),');
    } else {
      out.writeln(
        '      ${field.dartName}: ${field.type.decode("object.value['$wire'] ?? _missing(path, '$wire')", fieldPath)},',
      );
    }
  }
  out
    ..writeln('    );')
    ..writeln('  }')
    ..writeln()
    ..writeln(
      declaration.baseName == null
          ? '  ConvexObject encode(String path) {'
          : '  @override ConvexObject encode(String path) {',
    )
    ..writeln('    return ConvexObject({');
  if (declaration.discriminatorName != null) {
    out.writeln(
      "      '${_escape(declaration.discriminatorName!)}': ConvexString('${_escape(declaration.discriminatorValue!)}'),",
    );
  }
  for (final field in declaration.fields) {
    final wire = _escape(field.wireName);
    final fieldPath = "'\$path.$wire'";
    if (field.optional) {
      out.writeln(
        "      if (${field.dartName}.isPresent) '$wire': ${field.type.encode('${field.dartName}.value', fieldPath)},",
      );
    } else {
      out.writeln(
        "      '$wire': ${field.type.encode(field.dartName, fieldPath)},",
      );
    }
  }
  out
    ..writeln('    });')
    ..writeln('  }')
    ..writeln('}')
    ..writeln();
}

void _emitOpaqueUnion(
  StringBuffer out,
  String name,
  List<PayloadBinding> bindings,
) {
  final dartType = bindings.first.dartType;
  out
    ..writeln('$dartType _decode$name(ConvexValue value, String path) {')
    ..writeln('  final object = _decodeObject(value, path);')
    ..writeln("  final tag = _decodeString(object.value['kind'] ??")
    ..writeln("      _missing(path, 'kind'), '\$path.kind');")
    ..writeln('  return switch (tag) {');
  for (final binding in bindings) {
    out.writeln(
      "    '${_escape(binding.tag)}' => _decodePayload(() => const ${binding.codecClass}().decode(value), path),",
    );
  }
  out
    ..writeln(
      "    _ => throw ConvexDecodingException('\$path.kind', 'unknown payload tag \$tag'),",
    )
    ..writeln('  };')
    ..writeln('}')
    ..writeln()
    ..writeln('ConvexValue _encode$name($dartType value, String path) {')
    ..writeln("  final tag = value['kind'];")
    ..writeln('  return switch (tag) {');
  for (final binding in bindings) {
    out.writeln(
      "    '${_escape(binding.tag)}' => _encodePayload(() => const ${binding.codecClass}().encode(value), path),",
    );
  }
  out
    ..writeln(
      "    _ => throw ConvexEncodingException('\$path.kind', 'unknown payload tag \$tag'),",
    )
    ..writeln('  };')
    ..writeln('}')
    ..writeln();
}

String _emitApi(MappedContract contract) {
  final functionsByModule = <String, List<MappedFunction>>{};
  for (final function in contract.functions) {
    functionsByModule
        .putIfAbsent(function.contract.moduleName, () => [])
        .add(function);
  }
  final moduleNames = functionsByModule.keys.toList()..sort();
  final out = StringBuffer()
    ..writeln(_header())
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln("import '../transport/convex_transport.dart';")
    ..writeln("import 'convex_error_codes.dart';")
    ..writeln("import 'convex_models.dart';")
    ..writeln()
    ..writeln(_queryRuntime)
    ..writeln('abstract interface class IcarusConvexApi {')
    ..writeln(
      '  factory IcarusConvexApi(ConvexTransport transport) = _IcarusConvexApi;',
    );
  for (final module in moduleNames) {
    out.writeln('  ${pascalCase(module)}Module get ${lowerCamelCase(module)};');
  }
  out
    ..writeln('}')
    ..writeln()
    ..writeln('final class _IcarusConvexApi implements IcarusConvexApi {')
    ..writeln('  _IcarusConvexApi(ConvexTransport transport)');
  if (moduleNames.isEmpty) {
    out.writeln('      ;');
  } else {
    out.writeln('      :');
    for (var index = 0; index < moduleNames.length; index += 1) {
      final module = moduleNames[index];
      final ending = index == moduleNames.length - 1 ? ';' : ',';
      out.writeln(
        '        ${lowerCamelCase(module)} = _${pascalCase(module)}Module(transport)$ending',
      );
    }
  }
  for (final module in moduleNames) {
    out
      ..writeln('  @override')
      ..writeln(
        '  final ${pascalCase(module)}Module ${lowerCamelCase(module)};',
      );
  }
  out
    ..writeln('}')
    ..writeln();

  for (final module in moduleNames) {
    final functions = functionsByModule[module]!
      ..sort(
        (left, right) =>
            left.contract.functionName.compareTo(right.contract.functionName),
      );
    _emitModule(out, module, functions);
  }
  return out.toString();
}

void _emitModule(
  StringBuffer out,
  String module,
  List<MappedFunction> functions,
) {
  final moduleType = '${pascalCase(module)}Module';
  out.writeln('abstract interface class $moduleType {');
  for (final function in functions) {
    out.writeln('  ${_methodSignature(function)};');
  }
  out
    ..writeln('}')
    ..writeln()
    ..writeln('final class _$moduleType implements $moduleType {')
    ..writeln('  const _$moduleType(this._transport);')
    ..writeln('  final ConvexTransport _transport;');
  for (final function in functions) {
    out
      ..writeln('  @override')
      ..writeln('  ${_methodSignature(function)} {');
    final prefix = _functionPrefix(function);
    out.write('    final args = encode${prefix}Args(');
    if (function.argsFields.isNotEmpty) {
      for (final field in function.argsFields) {
        out.write('${field.dartName}: ${field.dartName},');
      }
    }
    out.writeln(');');
    final route = function.contract.identifier.replaceFirst('.js:', ':');
    final decode = 'decode${prefix}Result';
    switch (function.contract.kind) {
      case ConvexFunctionKind.query:
        out
          ..writeln('    return ConvexQuery(')
          ..writeln('      transport: _transport,')
          ..writeln("      name: '${_escape(route)}',")
          ..writeln('      args: args,')
          ..writeln('      decode: $decode,')
          ..writeln('    );');
      case ConvexFunctionKind.mutation:
        out.writeln(
          "    return _invoke(() => _transport.mutation('${_escape(route)}', args), $decode);",
        );
      case ConvexFunctionKind.action:
        out.writeln(
          "    return _invoke(() => _transport.action('${_escape(route)}', args), $decode);",
        );
    }
    out.writeln('  }');
  }
  out
    ..writeln('}')
    ..writeln();
}

String _functionPrefix(MappedFunction function) =>
    '${pascalCase(function.contract.moduleName)}'
    '${pascalCase(function.contract.functionName)}';

String _methodSignature(MappedFunction function) {
  final returnType = switch (function.contract.kind) {
    ConvexFunctionKind.query => 'ConvexQuery<${function.resultType.dartType}>',
    ConvexFunctionKind.mutation ||
    ConvexFunctionKind.action => 'Future<${function.resultType.dartType}>',
  };
  final parameters = StringBuffer();
  if (function.argsFields.isNotEmpty) {
    parameters.write('{');
    for (final field in function.argsFields) {
      if (field.optional) {
        parameters.write(
          'ConvexOptional<${field.type.dartType}> ${field.dartName} = '
          'const ConvexOptional.absent(),',
        );
      } else {
        parameters.write('required ${field.type.dartType} ${field.dartName},');
      }
    }
    parameters.write('}');
  }
  return '$returnType ${lowerCamelCase(function.contract.functionName)}($parameters)';
}

final class _RawPredicateEmitter {
  final _nameBySignature = <String, String>{};
  final _validatorByName = <String, ConvexValidator>{};
  var _next = 0;

  void registerRoot(String name, ConvexValidator validator) {
    _register(validator, preferredName: name);
  }

  String _register(ConvexValidator validator, {String? preferredName}) {
    final signature = validatorSignature(validator);
    final existing = _nameBySignature[signature];
    if (existing != null) return existing;
    final name = preferredName ?? '_matchesRaw${_next++}';
    _nameBySignature[signature] = name;
    _validatorByName[name] = validator;
    for (final child in _children(validator)) {
      _register(child);
    }
    return name;
  }

  String emit() {
    final out = StringBuffer();
    for (final entry in _validatorByName.entries) {
      out
        ..writeln('bool ${entry.key}(ConvexValue value) =>')
        ..writeln('    ${_predicate(entry.value, 'value')};')
        ..writeln();
    }
    return out.toString();
  }

  String _predicate(ConvexValidator validator, String input) {
    String child(ConvexValidator validator, String childValue) {
      final name = _nameBySignature[validatorSignature(validator)]!;
      return '$name($childValue)';
    }

    return switch (validator) {
      NullValidator() => '$input is ConvexNull',
      BooleanValidator() => '$input is ConvexBoolean',
      NumberValidator() => '($input is ConvexFloat || $input is ConvexInteger)',
      BigIntValidator() => '$input is ConvexBigInt',
      StringValidator() || IdValidator() => '$input is ConvexString',
      BytesValidator() => '$input is ConvexBytes',
      LiteralValidator(value: final literal) => _literalPredicate(
        literal,
        value: input,
      ),
      ArrayValidator(:final item) =>
        '$input is ConvexArray && $input.value.every((item) => ${child(item, 'item')})',
      ObjectValidator(:final fields) => _objectPredicate(fields, input, child),
      RecordValidator(:final keys, :final values) =>
        '$input is ConvexObject && $input.value.entries.every((entry) => '
            '${child(keys, 'ConvexString(entry.key)')} && ${child(values, 'entry.value')})',
      UnionValidator(:final members) =>
        '(${members.map((member) => child(member, input)).join(' || ')})',
    };
  }

  String _literalPredicate(Object? literal, {required String value}) {
    if (literal == null) return '$value is ConvexNull';
    if (literal is String) {
      return "$value is ConvexString && $value.value == '${_escape(literal)}'";
    }
    if (literal is bool) {
      return '$value is ConvexBoolean && $value.value == $literal';
    }
    if (literal is num) {
      return '($value is ConvexFloat && $value.value == $literal) || '
          '($value is ConvexInteger && $value.value == $literal)';
    }
    throw ContractException('Unsupported raw literal $literal');
  }

  String _objectPredicate(
    Map<String, ObjectField> fields,
    String value,
    String Function(ConvexValidator, String) child,
  ) {
    final allowed = fields.keys.map((key) => "'${_escape(key)}'").join(',');
    final checks = <String>[
      '$value is ConvexObject',
      '$value.value.keys.every(const {$allowed}.contains)',
    ];
    for (final entry in fields.entries) {
      final access = "$value.value['${_escape(entry.key)}']";
      if (entry.value.optional) {
        checks.add(
          '($access == null || ${child(entry.value.validator, '$access!')})',
        );
      } else {
        checks.add(
          '($access != null && ${child(entry.value.validator, '$access!')})',
        );
      }
    }
    return checks.join(' && ');
  }

  Iterable<ConvexValidator> _children(ConvexValidator validator) sync* {
    switch (validator) {
      case ArrayValidator(:final item):
        yield item;
      case ObjectValidator(:final fields):
        for (final field in fields.values) yield field.validator;
      case RecordValidator(:final keys, :final values):
        yield keys;
        yield values;
      case UnionValidator(:final members):
        yield* members;
      default:
        return;
    }
  }
}

String _escape(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$');

const _modelRuntime = r'''
final class ConvexOptional<T> {
  const ConvexOptional.absent()
      : isPresent = false,
        _value = null;
  const ConvexOptional.present(T value)
      : isPresent = true,
        _value = value;

  final bool isPresent;
  final T? _value;

  T get value {
    if (!isPresent) throw StateError('Optional value is absent');
    return _value as T;
  }
}

final class ConvexDecodingException extends FormatException {
  ConvexDecodingException(this.path, String message)
      : super('$path: $message');
  final String path;
}

final class ConvexEncodingException extends FormatException {
  ConvexEncodingException(this.path, String message)
      : super('$path: $message');
  final String path;
}

Never _missing(String path, String field) =>
    throw ConvexDecodingException('$path.$field', 'missing required field');

String _fieldPath(String path, String field) => '$path.$field';

String _indexPath(String path, int index) => '$path[$index]';

void _checkObjectFields(
  ConvexObject object,
  String path,
  Set<String> allowed,
) {
  for (final field in object.value.keys) {
    if (!allowed.contains(field)) {
      throw ConvexDecodingException('$path.$field', 'unexpected field');
    }
  }
}

Null _decodeNull(ConvexValue value, String path) {
  if (value is ConvexNull) return null;
  throw ConvexDecodingException(path, 'expected null');
}

bool _decodeBoolean(ConvexValue value, String path) {
  if (value case ConvexBoolean(:final value)) return value;
  throw ConvexDecodingException(path, 'expected boolean');
}

double _decodeNumber(ConvexValue value, String path) {
  if (value case ConvexFloat(:final value)) return value;
  if (value case ConvexInteger(:final value)) return value.toDouble();
  throw ConvexDecodingException(path, 'expected number');
}

ConvexValue _encodeNumber(double value, String path) {
  if (!value.isFinite) {
    throw ConvexEncodingException(path, 'number must be finite');
  }
  return ConvexFloat(value);
}

BigInt _decodeBigInt(ConvexValue value, String path) {
  if (value case ConvexBigInt(:final value)) return value;
  throw ConvexDecodingException(path, 'expected bigint');
}

String _decodeString(ConvexValue value, String path) {
  if (value case ConvexString(:final value)) return value;
  throw ConvexDecodingException(path, 'expected string');
}

Uint8List _decodeBytes(ConvexValue value, String path) {
  if (value case ConvexBytes(:final value)) return Uint8List.fromList(value);
  throw ConvexDecodingException(path, 'expected bytes');
}

ConvexArray _decodeArray(ConvexValue value, String path) {
  if (value is ConvexArray) return value;
  throw ConvexDecodingException(path, 'expected array');
}

ConvexObject _decodeObject(ConvexValue value, String path) {
  if (value is ConvexObject) return value;
  throw ConvexDecodingException(path, 'expected object');
}

T _expectLiteral<T>(T value, T expected, String path) {
  if (value == expected) return value;
  throw ConvexDecodingException(path, 'expected literal $expected');
}

T _decodePayload<T>(T Function() decode, String path) {
  try {
    return decode();
  } on FormatException catch (error) {
    throw ConvexDecodingException(path, error.message);
  }
}

ConvexValue _encodePayload(ConvexValue Function() encode, String path) {
  try {
    return encode();
  } on FormatException catch (error) {
    throw ConvexEncodingException(path, error.message);
  }
}

ConvexValue _decodeRaw(
  ConvexValue value,
  String path,
  bool Function(ConvexValue) accepts,
) {
  if (accepts(value)) return value;
  throw ConvexDecodingException(path, 'value does not satisfy closed union');
}
''';

const _queryRuntime = r'''
final class ConvexQuery<T> {
  const ConvexQuery({
    required ConvexTransport transport,
    required String name,
    required ConvexObject args,
    required T Function(ConvexValue) decode,
  })  : _transport = transport,
        _name = name,
        _args = args,
        _decode = decode;

  final ConvexTransport _transport;
  final String _name;
  final ConvexObject _args;
  final T Function(ConvexValue) _decode;

  Future<T> fetch() => _invoke(
        () => _transport.query(_name, _args),
        _decode,
      );

  Stream<T> watch() async* {
    try {
      await for (final value in _transport.subscribe(_name, _args)) {
        yield _decode(value);
      }
    } on ConvexTransportError catch (error) {
      throw ConvexFunctionException.fromTransport(error);
    }
  }
}

Future<T> _invoke<T>(
  Future<ConvexValue> Function() invoke,
  T Function(ConvexValue) decode,
) async {
  try {
    return decode(await invoke());
  } on ConvexTransportError catch (error) {
    throw ConvexFunctionException.fromTransport(error);
  }
}
''';
