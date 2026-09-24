import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:icarus/const/settings.dart';

/// One line of a release's patch notes.
class ReleaseNoteChange {
  const ReleaseNoteChange({required this.message, this.type});

  final String message;

  /// Free-form tag from the release metadata: `feature`, `fix`, `improvement`.
  final String? type;
}

/// One shipped version, as published in the updater manifest.
class ReleaseNotesEntry {
  const ReleaseNotesEntry({
    required this.version,
    required this.shortVersion,
    required this.changes,
    this.date,
  });

  /// Full version string, e.g. `4.6.2+102`.
  final String version;

  /// Build number, e.g. `102`. Compares against [Settings.versionNumber].
  final int shortVersion;
  final String? date;
  final List<ReleaseNoteChange> changes;

  /// `4.6.2` from `4.6.2+102`.
  String get versionName => version.split('+').first;

  bool get isInstalled => shortVersion == Settings.versionNumber;
  bool get isNewerThanInstalled => shortVersion > Settings.versionNumber;
}

/// Reads the patch notes of every shipped version from the same manifest the
/// desktop updater reads. Store and web builds read it too: it is only JSON.
class ReleaseNotes {
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function()? fetchManifestOverride;

  static Future<List<ReleaseNotesEntry>> fetch() async {
    final manifest = await _fetchManifest();
    if (manifest == null) {
      throw const ReleaseNotesUnavailable();
    }
    return parse(manifest);
  }

  static Future<Map<String, dynamic>?> _fetchManifest() async {
    final override = fetchManifestOverride;
    if (override != null) return override();

    try {
      final response = await http.get(Settings.desktopUpdaterArchiveUrl);
      if (response.statusCode != 200) {
        debugPrint('Failed to load release notes: ${response.statusCode}');
        return null;
      }
      return json.decode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Error fetching release notes: $e');
      return null;
    }
  }

  /// Newest first. Rebuilds of the same version (`4.6.2+101`, `4.6.2+102`)
  /// collapse into the highest build so a version reads as one release.
  static List<ReleaseNotesEntry> parse(Map<String, dynamic> manifest) {
    final rawItems = manifest['items'];
    if (rawItems is! List) return const [];

    final byVersionName = <String, ReleaseNotesEntry>{};
    for (final rawItem in rawItems) {
      if (rawItem is! Map) continue;
      final item = Map<String, dynamic>.from(rawItem);
      final entry = _parseEntry(item);
      if (entry == null) continue;
      final existing = byVersionName[entry.versionName];
      if (existing == null || entry.shortVersion > existing.shortVersion) {
        byVersionName[entry.versionName] = entry;
      }
    }

    final entries = byVersionName.values.toList()
      ..sort((a, b) => b.shortVersion.compareTo(a.shortVersion));
    return entries;
  }

  static ReleaseNotesEntry? _parseEntry(Map<String, dynamic> item) {
    final version = item['version']?.toString().trim();
    if (version == null || version.isEmpty) return null;

    final shortVersion =
        _toInt(item['shortVersion']) ?? int.tryParse(version.split('+').last);
    if (shortVersion == null) return null;

    final rawChanges = item['changes'];
    final changes = <ReleaseNoteChange>[];
    if (rawChanges is List) {
      for (final rawChange in rawChanges) {
        if (rawChange is! Map) continue;
        final message = rawChange['message']?.toString().trim();
        if (message == null || message.isEmpty) continue;
        changes.add(ReleaseNoteChange(
          message: message,
          type: rawChange['type']?.toString(),
        ));
      }
    }

    final date = item['date']?.toString().trim();
    return ReleaseNotesEntry(
      version: version,
      shortVersion: shortVersion,
      changes: changes,
      date: date == null || date.isEmpty ? null : date,
    );
  }

  static int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class ReleaseNotesUnavailable implements Exception {
  const ReleaseNotesUnavailable();

  @override
  String toString() => 'Release notes unavailable.';
}
