sealed class ConvexValidator {
  const ConvexValidator();
}

final class NullValidator extends ConvexValidator {
  const NullValidator();
}

final class BooleanValidator extends ConvexValidator {
  const BooleanValidator();
}

final class NumberValidator extends ConvexValidator {
  const NumberValidator();
}

final class BigIntValidator extends ConvexValidator {
  const BigIntValidator();
}

final class StringValidator extends ConvexValidator {
  const StringValidator();
}

final class BytesValidator extends ConvexValidator {
  const BytesValidator();
}

final class LiteralValidator extends ConvexValidator {
  const LiteralValidator(this.value);

  final Object? value;
}

final class IdValidator extends ConvexValidator {
  const IdValidator(this.tableName);

  final String tableName;
}

final class ArrayValidator extends ConvexValidator {
  const ArrayValidator(this.item);

  final ConvexValidator item;
}

final class ObjectField {
  const ObjectField({required this.validator, required this.optional});

  final ConvexValidator validator;
  final bool optional;
}

final class ObjectValidator extends ConvexValidator {
  const ObjectValidator(this.fields);

  final Map<String, ObjectField> fields;
}

final class RecordValidator extends ConvexValidator {
  const RecordValidator({required this.keys, required this.values});

  final ConvexValidator keys;
  final ConvexValidator values;
}

final class UnionValidator extends ConvexValidator {
  const UnionValidator(this.members);

  final List<ConvexValidator> members;
}

enum ConvexFunctionKind { query, mutation, action }

final class ConvexFunctionContract {
  const ConvexFunctionContract({
    required this.identifier,
    required this.moduleName,
    required this.functionName,
    required this.kind,
    required this.args,
    required this.result,
  });

  final String identifier;
  final String moduleName;
  final String functionName;
  final ConvexFunctionKind kind;
  final ObjectValidator args;
  final ConvexValidator result;
}

final class ConvexContract {
  const ConvexContract({required this.functions, required this.errorCodes});

  final List<ConvexFunctionContract> functions;
  final List<String> errorCodes;
}

final class PayloadBinding {
  const PayloadBinding({
    required this.tag,
    required this.codecClass,
    required this.dartType,
  });

  final String tag;
  final String codecClass;
  final String dartType;
}

final class ContractException implements Exception {
  const ContractException(this.message);

  final String message;

  @override
  String toString() => message;
}
