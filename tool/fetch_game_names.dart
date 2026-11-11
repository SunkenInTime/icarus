import 'dart:convert';
import 'dart:io';

/// Writes lib/l10n/official_game_names.dart: what Valorant itself calls each
/// agent, ability, role, weapon and map in the languages Icarus has. Players
/// know these names from the game, so Icarus never translates them itself.
///
/// The names come from valorant-api.com, which republishes the game client's
/// own text. Run this after a new agent, weapon or map ships, or after adding
/// a language to [_languages]:
///
///   dart run tool/fetch_game_names.dart
///
/// A name the game has no entry for (Icarus's own names, like "Astra Star")
/// is shown in English.
const _languages = {'ja': 'ja-JP', 'zh': 'zh-CN'};

Future<void> main() async {
  final client = HttpClient();
  Future<List<Map<String, dynamic>>> fetch(String path, String language) async {
    final separator = path.contains('?') ? '&' : '?';
    final request = await client.getUrl(Uri.parse(
      'https://valorant-api.com/v1/$path${separator}language=$language',
    ));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('$path ($language): ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    return ((jsonDecode(body) as Map<String, dynamic>)['data'] as List)
        .cast<Map<String, dynamic>>();
  }

  // English name (lower case) -> language -> the game's name.
  final names = <String, Map<String, String>>{};
  final mapNames = <String, Map<String, String>>{};

  final agents = await fetch('agents?isPlayableCharacter=true', 'en-US');
  final weapons = await fetch('weapons', 'en-US');
  final maps = await fetch('maps', 'en-US');
  for (final MapEntry(key: code, value: language) in _languages.entries) {
    void add(Map<String, Map<String, String>> into, Object? english,
        Object? translated) {
      if (english is! String || translated is! String) return;
      // The game breaks some long names over two lines for its own layout.
      final key = english.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
      into.putIfAbsent(key, () => {})[code] =
          translated.replaceAll(RegExp(r'\s*[\r\n]+\s*'), '').trim();
    }

    final translatedAgents = await fetch(
      'agents?isPlayableCharacter=true',
      language,
    );
    for (final agent in agents) {
      final translated = translatedAgents.firstWhere(
        (other) => other['uuid'] == agent['uuid'],
      );
      add(names, agent['displayName'], translated['displayName']);
      add(names, agent['role']?['displayName'],
          translated['role']?['displayName']);
      final abilities = (agent['abilities'] as List).cast<Map>();
      final translatedAbilities = (translated['abilities'] as List).cast<Map>();
      for (final ability in abilities) {
        final match = translatedAbilities.firstWhere(
          (other) => other['slot'] == ability['slot'],
          orElse: () => const {},
        );
        add(names, ability['displayName'], match['displayName']);
      }
    }
    final translatedWeapons = await fetch('weapons', language);
    for (final weapon in weapons) {
      final translated = translatedWeapons.firstWhere(
        (other) => other['uuid'] == weapon['uuid'],
      );
      add(names, weapon['displayName'], translated['displayName']);
    }
    final translatedMaps = await fetch('maps', language);
    for (final map in maps) {
      final translated = translatedMaps.firstWhere(
        (other) => other['uuid'] == map['uuid'],
      );
      add(mapNames, map['displayName'], translated['displayName']);
    }
  }
  client.close();

  String table(String name, Map<String, Map<String, String>> entries) {
    final buffer =
        StringBuffer('const $name = <String, Map<String, String>>{\n');
    for (final english in entries.keys.toList()..sort()) {
      final translations = entries[english]!
          .entries
          .map((entry) => '${_quote(entry.key)}: ${_quote(entry.value)}')
          .join(', ');
      buffer.writeln('  ${_quote(english)}: {$translations},');
    }
    buffer.writeln('};');
    return buffer.toString();
  }

  File('lib/l10n/official_game_names.dart').writeAsStringSync('''
// Written by tool/fetch_game_names.dart from the game's own text. Do not edit:
// run the tool again instead.

/// What Valorant calls an agent, ability, role or weapon, by its English name
/// in lower case, then by language.
${table('officialGameNames', names)}
/// The same for maps. Kept apart because a map and an ability can share an
/// English name.
${table('officialMapNames', mapNames)}''');
  stdout.writeln('${names.length} names, ${mapNames.length} maps');
}

String _quote(String text) =>
    "'${text.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";
