import 'dart:convert';
import 'dart:io';

import 'contract.dart';

const allowedPublicIds = <String>{
  'images.js:completeUpload.args.storageId:_storage',
};

ConvexContract parseContract({
  required File functionSpecFile,
  required File errorCodesFile,
}) {
  final decodedSpec = jsonDecode(functionSpecFile.readAsStringSync());
  if (decodedSpec is! Map<String, dynamic> ||
      decodedSpec.length != 1 ||
      decodedSpec['functions'] is! List) {
    throw const ContractException(
      'function_spec.json must contain only a functions array',
    );
  }
  final functions = <ConvexFunctionContract>[];
  final identifiers = <String>{};
  for (final rawFunction in decodedSpec['functions'] as List) {
    if (rawFunction is! Map) {
      throw const ContractException('Function entries must be objects');
    }
    final function = Map<String, dynamic>.from(rawFunction);
    final visibility = function['visibility'];
    if (visibility is! Map || visibility['kind'] != 'public') continue;
    final identifier = function['identifier'];
    if (identifier is! String || !identifiers.add(identifier)) {
      throw ContractException('Duplicate or invalid function $identifier');
    }
    final routeMatch = RegExp(
      r'^([A-Za-z][A-Za-z0-9_]*)\.js:([A-Za-z][A-Za-z0-9_]*)$',
    ).firstMatch(identifier);
    if (routeMatch == null) {
      throw ContractException('Invalid public function identifier $identifier');
    }
    final args = function['args'];
    final result = function['returns'];
    if (args == null) {
      throw ContractException('$identifier.args is missing a validator');
    }
    if (result == null) {
      throw ContractException('$identifier.returns is missing a validator');
    }
    final parsedArgs = _parseValidator(args, '$identifier.args', identifier);
    if (parsedArgs is! ObjectValidator) {
      throw ContractException('$identifier.args must be an object validator');
    }
    functions.add(
      ConvexFunctionContract(
        identifier: identifier,
        moduleName: routeMatch.group(1)!,
        functionName: routeMatch.group(2)!,
        kind: switch (function['functionType']) {
          'Query' => ConvexFunctionKind.query,
          'Mutation' => ConvexFunctionKind.mutation,
          'Action' => ConvexFunctionKind.action,
          final value => throw ContractException(
            '$identifier has unknown function type $value',
          ),
        },
        args: parsedArgs,
        result: _parseValidator(result, '$identifier.returns', identifier),
      ),
    );
  }
  functions.sort((left, right) => left.identifier.compareTo(right.identifier));

  final decodedCodes = jsonDecode(errorCodesFile.readAsStringSync());
  if (decodedCodes is! List || decodedCodes.any((code) => code is! String)) {
    throw const ContractException('error_codes.json must be a string array');
  }
  final errorCodes = decodedCodes.cast<String>();
  final expectedCodes = {...errorCodes}.toList()..sort();
  if (expectedCodes.length != errorCodes.length ||
      !_sameStrings(expectedCodes, errorCodes)) {
    throw const ContractException(
      'error_codes.json must be sorted without duplicates',
    );
  }
  return ConvexContract(functions: functions, errorCodes: errorCodes);
}

ConvexValidator _parseValidator(Object? raw, String path, String identifier) {
  if (raw is! Map) {
    throw ContractException('$path is not a validator object');
  }
  final validator = Map<String, dynamic>.from(raw);
  return switch (validator['type']) {
    'null' => const NullValidator(),
    'boolean' => const BooleanValidator(),
    'number' => const NumberValidator(),
    'bigint' || 'int64' => const BigIntValidator(),
    'string' => const StringValidator(),
    'bytes' => const BytesValidator(),
    'literal' => LiteralValidator(validator['value']),
    'id' => _parseId(validator, path, identifier),
    'array' => ArrayValidator(
      _parseValidator(validator['value'], '$path.item', identifier),
    ),
    'object' => _parseObject(validator, path, identifier),
    'record' => _parseRecord(validator, path, identifier),
    'union' => _parseUnion(validator, path, identifier),
    'any' => throw ContractException('$path uses forbidden validator any'),
    final type => throw ContractException(
      '$path uses unsupported validator ${type ?? 'null'}',
    ),
  };
}

IdValidator _parseId(
  Map<String, dynamic> validator,
  String path,
  String identifier,
) {
  final tableName = validator['tableName'];
  if (tableName is! String) {
    throw ContractException('$path has an invalid id table');
  }
  final allowlistKey = '$path:$tableName';
  if (!allowedPublicIds.contains(allowlistKey)) {
    throw ContractException('$path exposes Convex id $tableName');
  }
  return IdValidator(tableName);
}

ObjectValidator _parseObject(
  Map<String, dynamic> validator,
  String path,
  String identifier,
) {
  final rawFields = validator['value'];
  if (rawFields is! Map) {
    throw ContractException('$path has invalid object fields');
  }
  final fields = <String, ObjectField>{};
  for (final entry in rawFields.entries) {
    if (entry.key is! String || entry.value is! Map) {
      throw ContractException('$path has an invalid object field');
    }
    final field = Map<String, dynamic>.from(entry.value as Map);
    if (field['optional'] is! bool || field['fieldType'] == null) {
      throw ContractException('$path.${entry.key} has an invalid field');
    }
    fields[entry.key as String] = ObjectField(
      validator: _parseValidator(
        field['fieldType'],
        '$path.${entry.key}',
        identifier,
      ),
      optional: field['optional'] as bool,
    );
  }
  return ObjectValidator(Map.unmodifiable(fields));
}

RecordValidator _parseRecord(
  Map<String, dynamic> validator,
  String path,
  String identifier,
) {
  final values = validator['values'];
  if (values is! Map || values['fieldType'] == null) {
    throw ContractException('$path has invalid record values');
  }
  return RecordValidator(
    keys: _parseValidator(validator['keys'], '$path.key', identifier),
    values: _parseValidator(values['fieldType'], '$path.value', identifier),
  );
}

UnionValidator _parseUnion(
  Map<String, dynamic> validator,
  String path,
  String identifier,
) {
  final rawMembers = validator['value'];
  if (rawMembers is! List || rawMembers.isEmpty) {
    throw ContractException('$path has an empty union');
  }
  return UnionValidator([
    for (var index = 0; index < rawMembers.length; index += 1)
      _parseValidator(rawMembers[index], '$path.union$index', identifier),
  ]);
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
