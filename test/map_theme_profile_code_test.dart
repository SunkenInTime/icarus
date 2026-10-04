import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/services/map_theme_profile_code.dart';

void main() {
  final palette = MapThemePalette(
    baseColorValue: 0xFF18221A,
    detailColorValue: 0xFF7FA36B,
    highlightColorValue: 0xFFE3C567,
  );

  String rawCode(Map<String, dynamic> json) =>
      MapThemeProfileCode.prefix +
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

  test('a code round-trips its name and colors', () {
    final code = MapThemeProfileCode.encode(
        name: 'Lotus Moss', colors: palette.toJson());

    expect(code, startsWith('icarus-theme:'));
    expect(code, matches(RegExp(r'^icarus-theme:[A-Za-z0-9_-]+$')));
    final result = MapThemeProfileCode.parse(code);
    expect(result, isA<MapThemeProfileCodeValid>());
    result as MapThemeProfileCodeValid;
    expect(result.name, 'Lotus Moss');
    expect(MapThemePalette.fromJson(result.colors), palette);
  });

  test('names outside ASCII survive the trip', () {
    final code = MapThemeProfileCode.encode(
        name: 'Ascent 夜 ✦', colors: palette.toJson());
    final result = MapThemeProfileCode.parse(code) as MapThemeProfileCodeValid;
    expect(result.name, 'Ascent 夜 ✦');
  });

  test('a code inside a chat message is found and parsed', () {
    final code =
        MapThemeProfileCode.encode(name: 'Moss', colors: palette.toJson());
    final message = 'here is ours for lotus\n$code\nlooks cleaner';

    expect(MapThemeProfileCode.find(message), code);
    expect(MapThemeProfileCode.parse(message), isA<MapThemeProfileCodeValid>());
  });

  test('empty text and text without a code are told apart', () {
    expect(MapThemeProfileCode.parse('  '), isA<MapThemeProfileCodeEmpty>());
    expect(
      MapThemeProfileCode.parse('https://tracker.gg/valorant'),
      isA<MapThemeProfileCodeInvalid>(),
    );
    expect(MapThemeProfileCode.find('no code here'), isNull);
  });

  test('a code cut short reads as incomplete', () {
    final code =
        MapThemeProfileCode.encode(name: 'Moss', colors: palette.toJson());

    expect(
      MapThemeProfileCode.parse(code.substring(0, 40)),
      isA<MapThemeProfileCodeIncomplete>(),
    );
  });

  test('a code from a newer Icarus asks for an update', () {
    expect(
      MapThemeProfileCode.parse(rawCode({
        'v': 2,
        'name': 'Future',
        'base': '#000000',
        'detail': '#111111',
        'highlight': '#222222',
      })),
      isA<MapThemeProfileCodeNewerVersion>(),
    );
  });

  test('a code with a missing or malformed color is incomplete', () {
    expect(
      MapThemeProfileCode.parse(rawCode({
        'v': 1,
        'name': 'Broken',
        'base': '#000000',
        'detail': 'red',
      })),
      isA<MapThemeProfileCodeIncomplete>(),
    );
  });

  test('names are trimmed, capped, and never empty', () {
    final long = MapThemeProfileCode.parse(rawCode({
      'v': 1,
      'name': '   ${'x' * 60}   ',
      'base': '#000000',
      'detail': '#111111',
      'highlight': '#222222',
    })) as MapThemeProfileCodeValid;
    expect(long.name, 'x' * MapThemeProfileCode.maxNameLength);

    final unnamed = MapThemeProfileCode.parse(rawCode({
      'v': 1,
      'base': '#000000',
      'detail': '#111111',
      'highlight': '#222222',
    })) as MapThemeProfileCodeValid;
    expect(unnamed.name, 'Shared profile');
  });

  test('the name cap never cuts an emoji in half', () {
    final name = '${'x' * 39}\u{1F600}tail';
    final result = MapThemeProfileCode.parse(
      MapThemeProfileCode.encode(name: name, colors: palette.toJson()),
    ) as MapThemeProfileCodeValid;

    expect(result.name, '${'x' * 39}\u{1F600}');
    expect(result.name.runes.length, MapThemeProfileCode.maxNameLength);
  });

  test('versions this build does not know are not imported', () {
    for (final version in [0, -1]) {
      expect(
        MapThemeProfileCode.parse(rawCode({
          'v': version,
          'name': 'Old',
          'base': '#000000',
          'detail': '#111111',
          'highlight': '#222222',
        })),
        isA<MapThemeProfileCodeInvalid>(),
      );
    }
  });
}
