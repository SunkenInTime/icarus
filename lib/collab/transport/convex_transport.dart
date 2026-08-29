import 'dart:typed_data';

sealed class ConvexValue {
  const ConvexValue();

  factory ConvexValue.fromDart(Object? value) {
    if (value == null) return const ConvexNull();
    if (value is bool) return ConvexBoolean(value);
    if (value is int) return ConvexInteger(value);
    if (value is BigInt) return ConvexBigInt(value);
    if (value is double) {
      if (!value.isFinite) {
        throw FormatException('Convex numbers must be finite, received $value');
      }
      return ConvexFloat(value);
    }
    if (value is String) return ConvexString(value);
    if (value is Uint8List) return ConvexBytes(value);
    if (value is List) {
      return ConvexArray(value.map(ConvexValue.fromDart).toList());
    }
    if (value is Map) {
      return ConvexObject({
        for (final entry in value.entries)
          entry.key.toString(): ConvexValue.fromDart(entry.value),
      });
    }
    throw FormatException('Unsupported Convex value ${value.runtimeType}');
  }

  Object? toDart();
}

final class ConvexNull extends ConvexValue {
  const ConvexNull();

  @override
  Object? toDart() => null;
}

final class ConvexBoolean extends ConvexValue {
  const ConvexBoolean(this.value);

  final bool value;

  @override
  bool toDart() => value;
}

final class ConvexInteger extends ConvexValue {
  const ConvexInteger(this.value);

  final int value;

  @override
  int toDart() => value;
}

final class ConvexFloat extends ConvexValue {
  const ConvexFloat(this.value);

  final double value;

  @override
  double toDart() => value;
}

final class ConvexBigInt extends ConvexValue {
  const ConvexBigInt(this.value);

  final BigInt value;

  @override
  BigInt toDart() => value;
}

final class ConvexString extends ConvexValue {
  const ConvexString(this.value);

  final String value;

  @override
  String toDart() => value;
}

final class ConvexBytes extends ConvexValue {
  ConvexBytes(Uint8List value) : value = Uint8List.fromList(value);

  final Uint8List value;

  @override
  Uint8List toDart() => Uint8List.fromList(value);
}

final class ConvexArray extends ConvexValue {
  ConvexArray(List<ConvexValue> value) : value = List.unmodifiable(value);

  final List<ConvexValue> value;

  @override
  List<Object?> toDart() => value.map((item) => item.toDart()).toList();
}

final class ConvexObject extends ConvexValue {
  ConvexObject(Map<String, ConvexValue> value)
      : value = Map.unmodifiable(value);

  final Map<String, ConvexValue> value;

  @override
  Map<String, Object?> toDart() => {
        for (final entry in value.entries) entry.key: entry.value.toDart(),
      };
}

final class ConvexTransportError implements Exception {
  const ConvexTransportError({
    required this.rawCode,
    required this.message,
    this.data,
  });

  final String rawCode;
  final String message;
  final ConvexValue? data;

  @override
  String toString() => 'ConvexTransportError($rawCode, $message)';
}

abstract interface class ConvexTransport {
  Future<ConvexValue> query(String name, ConvexObject args);

  Future<ConvexValue> mutation(String name, ConvexObject args);

  Future<ConvexValue> action(String name, ConvexObject args);

  Stream<ConvexValue> subscribe(String name, ConvexObject args);
}
