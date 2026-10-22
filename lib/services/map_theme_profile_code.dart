import 'dart:convert';

/// A map theme profile as one line of text, so players can paste their map
/// colors into Discord and a teammate can import them.
///
/// The code is `icarus-theme:` followed by base64url (unpadded) of a
/// versioned JSON object:
///
///     {"v":1,"name":"Lotus Moss","base":"#18221A","detail":"#7FA36B","highlight":"#E3C567"}
///
/// Colors are `#RRGGBB` strings, the same shape `MapThemePalette.toJson`
/// writes. The codec depends on nothing but `dart:convert`, so any client or
/// server can read the format.
///
/// Parsing finds the code anywhere in the pasted text, so a code copied
/// together with the message around it still imports.
class MapThemeProfileCode {
  MapThemeProfileCode._();

  static const String prefix = 'icarus-theme:';
  static const int version = 1;
  static const int maxNameLength = 40;

  /// The longest code text decoded. A code [encode] writes stays far under
  /// it, since only the first [maxNameLength] characters of a name go in.
  /// Anything longer was not written by Icarus, and decoding it would only
  /// cost time on every keystroke in the import field.
  static const int maxEncodedLength = 4096;

  static final RegExp _codePattern = RegExp(r'icarus-theme:([A-Za-z0-9_-]+)');
  static final RegExp _hexColor = RegExp(r'^#[0-9a-fA-F]{6}$');

  /// [colors] holds `base`, `detail`, and `highlight` as `#RRGGBB`.
  static String encode({
    required String name,
    required Map<String, dynamic> colors,
  }) {
    final json = jsonEncode({
      'v': version,
      // Cut the way [parse] cuts, so a long name can't make the code longer
      // than [maxEncodedLength].
      'name': String.fromCharCodes(name.trim().runes.take(maxNameLength)),
      'base': colors['base'],
      'detail': colors['detail'],
      'highlight': colors['highlight'],
    });
    final encoded = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    return '$prefix$encoded';
  }

  /// The first profile code inside [text], or null when it holds none.
  static String? find(String text) {
    final match = _codePattern.firstMatch(text);
    if (match == null || match[1]!.length > maxEncodedLength) return null;
    return match[0];
  }

  static MapThemeProfileCodeResult parse(String text) {
    final match = _codePattern.firstMatch(text);
    if (match == null) {
      return text.trim().isEmpty
          ? const MapThemeProfileCodeEmpty()
          : const MapThemeProfileCodeInvalid();
    }
    if (match[1]!.length > maxEncodedLength) {
      return const MapThemeProfileCodeInvalid();
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64Url.decode(_padded(match[1]!))));
    } on FormatException {
      return const MapThemeProfileCodeIncomplete();
    }
    if (decoded is! Map<String, dynamic>) {
      return const MapThemeProfileCodeInvalid();
    }

    final codeVersion = decoded['v'];
    if (codeVersion is! int) return const MapThemeProfileCodeInvalid();
    if (codeVersion > version) return const MapThemeProfileCodeNewerVersion();
    if (codeVersion != version) return const MapThemeProfileCodeInvalid();

    final base = decoded['base'];
    final detail = decoded['detail'];
    final highlight = decoded['highlight'];
    if (![base, detail, highlight]
        .every((c) => c is String && _hexColor.hasMatch(c))) {
      return const MapThemeProfileCodeIncomplete();
    }

    final rawName = decoded['name'];
    final trimmedName = rawName is String ? rawName.trim() : '';
    // Cap by code point so an emoji at the limit is never cut in half.
    final name = trimmedName.isEmpty
        ? 'Shared profile'
        : String.fromCharCodes(trimmedName.runes.take(maxNameLength));

    return MapThemeProfileCodeValid(
      name: name,
      colors: {
        'base': (base as String).toUpperCase(),
        'detail': (detail as String).toUpperCase(),
        'highlight': (highlight as String).toUpperCase(),
      },
    );
  }

  static String _padded(String value) =>
      value.padRight(value.length + (4 - value.length % 4) % 4, '=');
}

sealed class MapThemeProfileCodeResult {
  const MapThemeProfileCodeResult();
}

class MapThemeProfileCodeValid extends MapThemeProfileCodeResult {
  const MapThemeProfileCodeValid({required this.name, required this.colors});

  final String name;

  /// `base`, `detail`, and `highlight` as `#RRGGBB`, ready for
  /// `MapThemePalette.fromJson`.
  final Map<String, String> colors;
}

/// Nothing pasted yet.
class MapThemeProfileCodeEmpty extends MapThemeProfileCodeResult {
  const MapThemeProfileCodeEmpty();
}

/// Text with no profile code in it.
class MapThemeProfileCodeInvalid extends MapThemeProfileCodeResult {
  const MapThemeProfileCodeInvalid();
}

/// A code that was cut short or damaged on the way.
class MapThemeProfileCodeIncomplete extends MapThemeProfileCodeResult {
  const MapThemeProfileCodeIncomplete();
}

/// A code written by a newer Icarus than this one.
class MapThemeProfileCodeNewerVersion extends MapThemeProfileCodeResult {
  const MapThemeProfileCodeNewerVersion();
}
