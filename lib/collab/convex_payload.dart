import 'dart:convert';

dynamic decodeConvexPayload(dynamic value) {
  if (value is String) {
    return jsonDecode(value);
  }

  return value;
}

Map<String, dynamic> decodeConvexMap(dynamic value) {
  final decoded = decodeConvexPayload(value);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  throw const FormatException(
    'Expected Convex payload to decode to a JSON object.',
  );
}

List<dynamic> decodeConvexList(dynamic value) {
  final decoded = decodeConvexPayload(value);
  if (decoded == null) {
    return const [];
  }
  if (decoded is List) {
    return List<dynamic>.from(decoded);
  }
  throw const FormatException(
    'Expected Convex payload to decode to a JSON array.',
  );
}
