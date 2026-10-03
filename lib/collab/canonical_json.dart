import 'dart:convert';

Object? canonicalCloudJsonValue(Object? value) {
  if (value is Map) {
    final entries = value.entries
        .map((entry) => MapEntry(entry.key.toString(), entry.value))
        .toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    return <String, Object?>{
      for (final entry in entries)
        entry.key: canonicalCloudJsonValue(entry.value),
    };
  }
  if (value is List) {
    return value.map(canonicalCloudJsonValue).toList(growable: false);
  }
  if (value is num && value.isFinite) {
    return value.toDouble();
  }
  return value;
}

String canonicalCloudJsonEncode(Object? value) {
  return jsonEncode(canonicalCloudJsonValue(value));
}

bool cloudJsonEquivalent(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  return canonicalCloudJsonEncode(left) == canonicalCloudJsonEncode(right);
}
