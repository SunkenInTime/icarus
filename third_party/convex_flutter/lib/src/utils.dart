import 'dart:convert';

Map<String, String> buildArgs(Map<String, dynamic> record) {
  return {for (var entry in record.entries) entry.key: jsonEncode(entry.value)};
}
