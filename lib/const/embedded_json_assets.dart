import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class EmbeddedJsonAssets {
  static const String mapDataPath = 'assets/data/map_data.json';
  static const String matchDataPath = 'assets/data/match_data.json';

  static Future<Map<String, dynamic>> loadMapData() async {
    final raw = await rootBundle.loadString(mapDataPath);
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> loadMatchData() async {
    final raw = await rootBundle.loadString(matchDataPath);
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}
