import 'dart:convert';

import 'contract.dart';

final class MappedContract {
  const MappedContract({
    required this.contract,
    required this.functions,
    required this.models,
    required this.enums,
    required this.unions,
    required this.rawValidators,
    required this.opaqueUnions,
    required this.payloadBindings,
  });

  final ConvexContract contract;
  final List<MappedFunction> functions;
  final List<ModelDeclaration> models;
  final List<EnumDeclaration> enums;
  final List<UnionDeclaration> unions;
  final List<RawValidatorDeclaration> rawValidators;
  final Map<String, List<PayloadBinding>> opaqueUnions;
  final Map<String, PayloadBinding> payloadBindings;
}

final class MappedFunction {
  const MappedFunction({
    required this.contract,
    required this.argsFields,
    required this.resultType,
  });

  final ConvexFunctionContract contract;
  final List<MappedField> argsFields;
  final MappedType resultType;
}

final class MappedField {
  const MappedField({
    required this.wireName,
    required this.dartName,
    required this.type,
    required this.optional,
  });

  final String wireName;
  final String dartName;
  final MappedType type;
  final bool optional;
}

final class ModelDeclaration {
  const ModelDeclaration({
    required this.name,
    required this.fields,
    required this.signature,
    this.baseName,
    this.discriminatorName,
    this.discriminatorValue,
  });

  final String name;
  final List<MappedField> fields;
  final String signature;
  final String? baseName;
  final String? discriminatorName;
  final String? discriminatorValue;
}

final class EnumValueDeclaration {
  const EnumValueDeclaration({required this.name, required this.wireValue});

  final String name;
  final String wireValue;
}

final class EnumDeclaration {
  const EnumDeclaration({
    required this.name,
    required this.values,
    required this.signature,
  });

  final String name;
  final List<EnumValueDeclaration> values;
  final String signature;
}

final class UnionVariantDeclaration {
  const UnionVariantDeclaration({
    required this.discriminatorValue,
    required this.model,
  });

  final String discriminatorValue;
  final ModelDeclaration model;
}

final class UnionDeclaration {
  const UnionDeclaration({
    required this.name,
    required this.discriminatorName,
    required this.variants,
    required this.signature,
  });

  final String name;
  final String discriminatorName;
  final List<UnionVariantDeclaration> variants;
  final String signature;
}

final class RawValidatorDeclaration {
  const RawValidatorDeclaration({
    required this.name,
    required this.validator,
    required this.signature,
  });

  final String name;
  final ConvexValidator validator;
  final String signature;
}

sealed class MappedType {
  const MappedType();

  String get dartType;

  String decode(String value, String path);

  String encode(String value, String path);
}

final class PrimitiveMappedType extends MappedType {
  const PrimitiveMappedType(this.kind);

  final String kind;

  @override
  String get dartType => switch (kind) {
    'null' => 'Null',
    'boolean' => 'bool',
    'number' => 'double',
    'bigint' => 'BigInt',
    'string' || 'id' => 'String',
    'bytes' => 'Uint8List',
    _ => throw StateError('Unknown primitive $kind'),
  };

  @override
  String decode(String value, String path) => switch (kind) {
    'null' => '_decodeNull($value, $path)',
    'boolean' => '_decodeBoolean($value, $path)',
    'number' => '_decodeNumber($value, $path)',
    'bigint' => '_decodeBigInt($value, $path)',
    'string' || 'id' => '_decodeString($value, $path)',
    'bytes' => '_decodeBytes($value, $path)',
    _ => throw StateError('Unknown primitive $kind'),
  };

  @override
  String encode(String value, String path) => switch (kind) {
    'null' => 'const ConvexNull()',
    'boolean' => 'ConvexBoolean($value)',
    'number' => '_encodeNumber($value, $path)',
    'bigint' => 'ConvexBigInt($value)',
    'string' || 'id' => 'ConvexString($value)',
    'bytes' => 'ConvexBytes($value)',
    _ => throw StateError('Unknown primitive $kind'),
  };
}

final class NullableMappedType extends MappedType {
  const NullableMappedType(this.inner);

  final MappedType inner;

  @override
  String get dartType => '${inner.dartType}?';

  @override
  String decode(String value, String path) =>
      '($value) is ConvexNull ? null : ${inner.decode(value, path)}';

  @override
  String encode(String value, String path) =>
      '$value == null ? const ConvexNull() : ${inner.encode('$value!', path)}';
}

final class ListMappedType extends MappedType {
  const ListMappedType(this.item);

  final MappedType item;

  @override
  String get dartType => 'List<${item.dartType}>';

  @override
  String decode(String value, String path) =>
      '_decodeArray($value, $path).value.indexed.map((entry) => '
      '${item.decode('entry.\$2', '_indexPath($path, entry.\$1)')}).toList(growable: false)';

  @override
  String encode(String value, String path) =>
      'ConvexArray($value.indexed.map((entry) => '
      '${item.encode('entry.\$2', '_indexPath($path, entry.\$1)')}).toList(growable: false))';
}

final class MapMappedType extends MappedType {
  const MapMappedType(this.valueType);

  final MappedType valueType;

  @override
  String get dartType => 'Map<String, ${valueType.dartType}>';

  @override
  String decode(String value, String path) =>
      'Map.unmodifiable(_decodeObject($value, $path).value.map((key, item) => '
      'MapEntry(key, ${valueType.decode('item', '_fieldPath($path, key)')})))';

  @override
  String encode(String value, String path) =>
      'ConvexObject($value.map((key, item) => '
      'MapEntry(key, ${valueType.encode('item', '_fieldPath($path, key)')})))';
}

final class DeclarationMappedType extends MappedType {
  const DeclarationMappedType(this.name);

  final String name;

  @override
  String get dartType => name;

  @override
  String decode(String value, String path) => '$name.decode($value, $path)';

  @override
  String encode(String value, String path) => '$value.encode($path)';
}

final class EnumMappedType extends MappedType {
  const EnumMappedType(this.name);

  final String name;

  @override
  String get dartType => name;

  @override
  String decode(String value, String path) =>
      '$name.fromWireName(_decodeString($value, $path), $path)';

  @override
  String encode(String value, String path) => 'ConvexString($value.wireName)';
}

final class LiteralMappedType extends MappedType {
  const LiteralMappedType(this.value, this.inner);

  final Object? value;
  final MappedType inner;

  @override
  String get dartType => inner.dartType;

  @override
  String decode(String input, String path) {
    final decoded = inner.decode(input, path);
    return '_expectLiteral($decoded, ${jsonEncode(value)}, $path)';
  }

  @override
  String encode(String input, String path) =>
      inner.encode('_expectLiteral($input, ${jsonEncode(value)}, $path)', path);
}

final class OpaqueMappedType extends MappedType {
  const OpaqueMappedType(this.binding);

  final PayloadBinding binding;

  @override
  String get dartType => binding.dartType;

  @override
  String decode(String value, String path) =>
      '_decodePayload(() => const ${binding.codecClass}().decode($value), $path)';

  @override
  String encode(String value, String path) =>
      '_encodePayload(() => const ${binding.codecClass}().encode($value), $path)';
}

final class OpaqueUnionMappedType extends MappedType {
  const OpaqueUnionMappedType({required this.dartTypeName, required this.name});

  final String dartTypeName;
  final String name;

  @override
  String get dartType => dartTypeName;

  @override
  String decode(String value, String path) => '_decode$name($value, $path)';

  @override
  String encode(String value, String path) => '_encode$name($value, $path)';
}

final class RawMappedType extends MappedType {
  const RawMappedType(this.validatorName);

  final String validatorName;

  @override
  String get dartType => 'ConvexValue';

  @override
  String decode(String value, String path) =>
      '_decodeRaw($value, $path, $validatorName)';

  @override
  String encode(String value, String path) =>
      '_decodeRaw($value, $path, $validatorName)';
}

MappedContract mapContract(
  ConvexContract contract,
  Map<String, PayloadBinding> payloadBindings,
) {
  final mapper = _ContractMapper(contract, payloadBindings);
  return mapper.map();
}

final class _ContractMapper {
  _ContractMapper(this.contract, this.payloadBindings);

  final ConvexContract contract;
  final Map<String, PayloadBinding> payloadBindings;
  final models = <ModelDeclaration>[];
  final enums = <EnumDeclaration>[];
  final unions = <UnionDeclaration>[];
  final rawValidators = <RawValidatorDeclaration>[];
  final _modelBySignature = <String, ModelDeclaration>{};
  final _enumBySignature = <String, EnumDeclaration>{};
  final _unionBySignature = <String, UnionDeclaration>{};
  final _rawBySignature = <String, RawValidatorDeclaration>{};
  final _declarationSignatures = <String, String>{};
  final _usedPayloadTags = <String>{};

  MappedContract map() {
    final mappedFunctions = <MappedFunction>[];
    for (final function in contract.functions) {
      final prefix =
          '${pascalCase(function.moduleName)}${pascalCase(function.functionName)}';
      final argsFields = _mapObjectFields(function.args, '${prefix}Args');
      final resultType = _mapType(function.result, '${prefix}Result');
      mappedFunctions.add(
        MappedFunction(
          contract: function,
          argsFields: argsFields,
          resultType: resultType,
        ),
      );
    }
    final missingBindings = payloadBindings.keys.toSet()
      ..removeAll(_usedPayloadTags);
    if (missingBindings.isNotEmpty) {
      final sorted = missingBindings.toList()..sort();
      throw ContractException('Unused payload bindings: ${sorted.join(', ')}');
    }
    return MappedContract(
      contract: contract,
      functions: mappedFunctions,
      models: List.unmodifiable(models),
      enums: List.unmodifiable(enums),
      unions: List.unmodifiable(unions),
      rawValidators: List.unmodifiable(rawValidators),
      opaqueUnions: Map.unmodifiable(_opaqueUnions),
      payloadBindings: payloadBindings,
    );
  }

  MappedType _mapType(ConvexValidator validator, String suggestedName) {
    return switch (validator) {
      NullValidator() => const PrimitiveMappedType('null'),
      BooleanValidator() => const PrimitiveMappedType('boolean'),
      NumberValidator() => const PrimitiveMappedType('number'),
      BigIntValidator() => const PrimitiveMappedType('bigint'),
      StringValidator() => const PrimitiveMappedType('string'),
      BytesValidator() => const PrimitiveMappedType('bytes'),
      IdValidator() => const PrimitiveMappedType('id'),
      LiteralValidator(:final value) => _mapLiteral(value, suggestedName),
      ArrayValidator(:final item) => ListMappedType(
        _mapType(item, '${suggestedName}Item'),
      ),
      ObjectValidator() => _mapObject(validator, suggestedName),
      RecordValidator(:final keys, :final values) => _mapRecord(
        keys,
        values,
        suggestedName,
      ),
      UnionValidator() => _mapUnion(validator, suggestedName),
    };
  }

  MappedType _mapLiteral(Object? value, String suggestedName) {
    if (value is String) {
      return _mapEnum([value], suggestedName);
    }
    if (value == null) return const PrimitiveMappedType('null');
    if (value is bool) {
      return LiteralMappedType(value, const PrimitiveMappedType('boolean'));
    }
    if (value is num) {
      return LiteralMappedType(value, const PrimitiveMappedType('number'));
    }
    throw ContractException('$suggestedName has unsupported literal $value');
  }

  MappedType _mapObject(ObjectValidator validator, String suggestedName) {
    final payloadTag = _payloadTag(validator);
    if (payloadTag != null) {
      final binding = payloadBindings[payloadTag];
      if (binding == null) {
        throw ContractException('Missing payload binding for tag $payloadTag');
      }
      _usedPayloadTags.add(payloadTag);
      return OpaqueMappedType(binding);
    }
    final signature = validatorSignature(validator);
    final existing = _modelBySignature[signature];
    if (existing != null) return DeclarationMappedType(existing.name);
    final name = pascalCase(suggestedName);
    _claimName(name, signature);
    final fields = _mapObjectFields(validator, name);
    final declaration = ModelDeclaration(
      name: name,
      fields: fields,
      signature: signature,
    );
    _modelBySignature[signature] = declaration;
    models.add(declaration);
    return DeclarationMappedType(name);
  }

  List<MappedField> _mapObjectFields(
    ObjectValidator validator,
    String suggestedName, {
    String? excludedField,
  }) {
    final fields = <MappedField>[];
    final usedNames = <String>{};
    for (final entry in validator.fields.entries) {
      if (entry.key == excludedField) continue;
      final dartName = lowerCamelCase(entry.key);
      if (!usedNames.add(dartName)) {
        throw ContractException(
          '$suggestedName has colliding field names at ${entry.key}',
        );
      }
      fields.add(
        MappedField(
          wireName: entry.key,
          dartName: dartName,
          type: _mapType(
            entry.value.validator,
            '$suggestedName${pascalCase(entry.key)}',
          ),
          optional: entry.value.optional,
        ),
      );
    }
    return List.unmodifiable(fields);
  }

  MappedType _mapRecord(
    ConvexValidator keys,
    ConvexValidator values,
    String suggestedName,
  ) {
    if (keys is! StringValidator) {
      throw ContractException('$suggestedName record keys must be strings');
    }
    return MapMappedType(_mapType(values, '${suggestedName}Value'));
  }

  MappedType _mapUnion(UnionValidator validator, String suggestedName) {
    final withoutNull = validator.members
        .where((member) => member is! NullValidator)
        .toList();
    final nullable = withoutNull.length != validator.members.length;
    if (nullable && withoutNull.length == 1) {
      return NullableMappedType(_mapType(withoutNull.single, suggestedName));
    }
    if (withoutNull.every((member) => member is LiteralValidator)) {
      final values = withoutNull
          .cast<LiteralValidator>()
          .map((member) => member.value)
          .toList();
      if (values.every((value) => value is String)) {
        final mapped = _mapEnum(values.cast<String>(), suggestedName);
        return nullable ? NullableMappedType(mapped) : mapped;
      }
    }
    if (withoutNull.every((member) => member is ObjectValidator)) {
      final objectMembers = withoutNull.cast<ObjectValidator>();
      final payloadTags = objectMembers.map(_payloadTag).toList();
      if (payloadTags.every((tag) => tag != null)) {
        final bindings = payloadTags.map((tag) {
          final binding = payloadBindings[tag];
          if (binding == null) {
            throw ContractException('Missing payload binding for tag $tag');
          }
          _usedPayloadTags.add(tag!);
          return binding;
        }).toList();
        final dartTypes = bindings.map((binding) => binding.dartType).toSet();
        if (dartTypes.length != 1) {
          throw ContractException(
            '$suggestedName payload union has incompatible Dart types',
          );
        }
        final name = pascalCase(suggestedName);
        final mapped = OpaqueUnionMappedType(
          dartTypeName: dartTypes.single,
          name: name,
        );
        _registerOpaqueUnion(name, bindings);
        return nullable ? NullableMappedType(mapped) : mapped;
      }
      final discriminator = _findDiscriminator(objectMembers);
      if (discriminator != null) {
        final mapped = _mapDiscriminatedUnion(
          validator,
          objectMembers,
          discriminator,
          suggestedName,
        );
        return nullable ? NullableMappedType(mapped) : mapped;
      }
    }
    final signature = validatorSignature(validator);
    final existing = _rawBySignature[signature];
    if (existing != null) return RawMappedType(existing.name);
    final name = '_validate${pascalCase(suggestedName)}';
    _claimName(name, signature);
    final declaration = RawValidatorDeclaration(
      name: name,
      validator: validator,
      signature: signature,
    );
    _rawBySignature[signature] = declaration;
    rawValidators.add(declaration);
    return RawMappedType(name);
  }

  MappedType _mapEnum(List<String> values, String suggestedName) {
    final sorted = {...values}.toList()..sort();
    if (sorted.length != values.length) {
      throw ContractException('$suggestedName has duplicate literal members');
    }
    final signature = 'enum:${sorted.map(jsonEncode).join(',')}';
    final existing = _enumBySignature[signature];
    if (existing != null) return EnumMappedType(existing.name);
    final name = pascalCase(suggestedName);
    _claimName(name, signature);
    final usedNames = <String>{};
    final enumValues = <EnumValueDeclaration>[];
    for (final wireValue in sorted) {
      final enumName = lowerCamelCase(wireValue);
      if (!usedNames.add(enumName)) {
        throw ContractException('$name has colliding enum member $wireValue');
      }
      enumValues.add(
        EnumValueDeclaration(name: enumName, wireValue: wireValue),
      );
    }
    final declaration = EnumDeclaration(
      name: name,
      values: enumValues,
      signature: signature,
    );
    _enumBySignature[signature] = declaration;
    enums.add(declaration);
    return EnumMappedType(name);
  }

  MappedType _mapDiscriminatedUnion(
    UnionValidator validator,
    List<ObjectValidator> members,
    String discriminator,
    String suggestedName,
  ) {
    final signature = validatorSignature(validator);
    final existing = _unionBySignature[signature];
    if (existing != null) return DeclarationMappedType(existing.name);
    final name = pascalCase(suggestedName);
    _claimName(name, signature);
    final variants = <UnionVariantDeclaration>[];
    for (final member in members) {
      final literal =
          member.fields[discriminator]!.validator as LiteralValidator;
      final wireValue = literal.value! as String;
      final variantName = '$name${pascalCase(wireValue)}';
      final modelSignature = '${validatorSignature(member)}:base=$name';
      _claimName(variantName, modelSignature);
      final model = ModelDeclaration(
        name: variantName,
        fields: _mapObjectFields(
          member,
          variantName,
          excludedField: discriminator,
        ),
        signature: modelSignature,
        baseName: name,
        discriminatorName: discriminator,
        discriminatorValue: wireValue,
      );
      models.add(model);
      variants.add(
        UnionVariantDeclaration(discriminatorValue: wireValue, model: model),
      );
    }
    final declaration = UnionDeclaration(
      name: name,
      discriminatorName: discriminator,
      variants: variants,
      signature: signature,
    );
    _unionBySignature[signature] = declaration;
    unions.add(declaration);
    return DeclarationMappedType(name);
  }

  final _opaqueUnions = <String, List<PayloadBinding>>{};

  void _registerOpaqueUnion(String name, List<PayloadBinding> bindings) {
    final signature = bindings.map((binding) => binding.tag).join('|');
    final previous = _declarationSignatures[name];
    if (previous != null && previous != 'opaque:$signature') {
      throw ContractException('Generated declaration name collision at $name');
    }
    _declarationSignatures[name] = 'opaque:$signature';
    _opaqueUnions[name] = bindings;
  }

  String? _payloadTag(ObjectValidator validator) {
    final kind = validator.fields['kind'];
    final version = validator.fields['payloadVersion'];
    final data = validator.fields['data'];
    if (kind == null || version == null || data == null) return null;
    if (kind.optional || version.optional || data.optional) return null;
    if (kind.validator case LiteralValidator(value: final String tag)) {
      if (version.validator is NumberValidator &&
          data.validator is RecordValidator) {
        return tag;
      }
    }
    return null;
  }

  String? _findDiscriminator(List<ObjectValidator> members) {
    final preferred = ['type', 'status', 'kind', 'targetType', 'provider'];
    for (final name in preferred) {
      final values = <String>{};
      var valid = true;
      for (final member in members) {
        final field = member.fields[name];
        if (field == null || field.optional) {
          valid = false;
          break;
        }
        if (field.validator case LiteralValidator(value: final String value)) {
          if (!values.add(value)) valid = false;
        } else {
          valid = false;
        }
      }
      if (valid) return name;
    }
    return null;
  }

  void _claimName(String name, String signature) {
    final existing = _declarationSignatures[name];
    if (existing != null && existing != signature) {
      throw ContractException('Generated declaration name collision at $name');
    }
    _declarationSignatures[name] = signature;
  }
}

String validatorSignature(ConvexValidator validator) => switch (validator) {
  NullValidator() => 'null',
  BooleanValidator() => 'boolean',
  NumberValidator() => 'number',
  BigIntValidator() => 'bigint',
  StringValidator() => 'string',
  BytesValidator() => 'bytes',
  LiteralValidator(:final value) => 'literal:${jsonEncode(value)}',
  IdValidator(:final tableName) => 'id:$tableName',
  ArrayValidator(:final item) => 'array:${validatorSignature(item)}',
  ObjectValidator(:final fields) =>
    'object:{${fields.entries.map((entry) => '${jsonEncode(entry.key)}:${entry.value.optional ? '?' : '!'}${validatorSignature(entry.value.validator)}').join(',')}}',
  RecordValidator(:final keys, :final values) =>
    'record:${validatorSignature(keys)}:${validatorSignature(values)}',
  UnionValidator(:final members) =>
    'union:[${members.map(validatorSignature).join(',')}]',
};

const _dartKeywords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'Function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

String pascalCase(String value) {
  final words = _words(value);
  if (words.isEmpty) throw ContractException('Cannot map empty Dart name');
  return words
      .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
      .join();
}

String lowerCamelCase(String value) {
  final pascal = pascalCase(value);
  var result = '${pascal[0].toLowerCase()}${pascal.substring(1)}';
  if (_dartKeywords.contains(result)) result = '${result}Value';
  return result;
}

List<String> _words(String value) {
  final separated = value
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]} ${match[2]}',
      )
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), ' ')
      .trim();
  if (separated.isEmpty) return const [];
  return separated
      .split(RegExp(r'\s+'))
      .map((word) => word.toLowerCase())
      .toList();
}
