import 'package:flutter/material.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:path/path.dart' as path;

const String archiveMetadataFileName = 'icarus-metadata.json';
const String libraryBackupRootDirectoryName = 'icarus-library-backup';
const int archiveManifestSchemaVersion = 1;

enum ArchiveType {
  folderTree('folder_tree'),
  libraryBackup('library_backup');

  const ArchiveType(this.jsonValue);

  final String jsonValue;

  static ArchiveType fromJsonValue(String value) {
    return ArchiveType.values.firstWhere(
      (candidate) => candidate.jsonValue == value,
      orElse: () => throw FormatException('Unknown archive type: $value'),
    );
  }
}

class ArchiveIconDescriptor {
  const ArchiveIconDescriptor({
    required this.codePoint,
    required this.fontFamily,
    required this.fontPackage,
    required this.matchTextDirection,
  });

  final int codePoint;
  final String? fontFamily;
  final String? fontPackage;
  final bool matchTextDirection;

  factory ArchiveIconDescriptor.fromIconData(IconData icon) {
    return ArchiveIconDescriptor(
      codePoint: icon.codePoint,
      fontFamily: icon.fontFamily,
      fontPackage: icon.fontPackage,
      matchTextDirection: icon.matchTextDirection,
    );
  }

  IconData toIconData() {
    return IconData(
      codePoint,
      fontFamily: fontFamily,
      fontPackage: fontPackage,
      matchTextDirection: matchTextDirection,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'codePoint': codePoint,
      'fontFamily': fontFamily,
      'fontPackage': fontPackage,
      'matchTextDirection': matchTextDirection,
    };
  }

  factory ArchiveIconDescriptor.fromJson(Map<String, dynamic> json) {
    return ArchiveIconDescriptor(
      codePoint: _readRequiredInt(json, 'codePoint'),
      fontFamily: _readNullableString(json, 'fontFamily'),
      fontPackage: _readNullableString(json, 'fontPackage'),
      matchTextDirection: _readRequiredBool(json, 'matchTextDirection'),
    );
  }
}

class ArchiveFolderEntry {
  const ArchiveFolderEntry({
    required this.manifestId,
    required this.name,
    required this.parentManifestId,
    required this.archivePath,
    required this.icon,
    required this.color,
    required this.customColorValue,
  });

  final String manifestId;
  final String name;
  final String? parentManifestId;
  final String archivePath;
  final ArchiveIconDescriptor icon;
  final FolderColor color;
  final int? customColorValue;

  Map<String, dynamic> toJson() {
    return {
      'manifestId': manifestId,
      'name': name,
      'parentManifestId': parentManifestId,
      'archivePath': archivePath,
      'icon': icon.toJson(),
      'color': color.name,
      if (customColorValue != null) 'customColorValue': customColorValue,
    };
  }

  factory ArchiveFolderEntry.fromJson(Map<String, dynamic> json) {
    final colorName = _readRequiredString(json, 'color');
    return ArchiveFolderEntry(
      manifestId: _readRequiredString(json, 'manifestId'),
      name: _readRequiredString(json, 'name'),
      parentManifestId: _readNullableString(json, 'parentManifestId'),
      archivePath:
          normalizeArchivePath(_readStringAllowEmpty(json, 'archivePath')),
      icon: ArchiveIconDescriptor.fromJson(_readRequiredMap(json, 'icon')),
      color: FolderColor.values.firstWhere(
        (candidate) => candidate.name == colorName,
        orElse: () => throw FormatException('Unknown folder color: $colorName'),
      ),
      customColorValue: _readNullableInt(json, 'customColorValue'),
    );
  }
}

class ArchiveStrategyEntry {
  const ArchiveStrategyEntry({
    required this.name,
    required this.archivePath,
    required this.folderManifestId,
  });

  final String name;
  final String archivePath;
  final String? folderManifestId;

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'archivePath': archivePath,
      'folderManifestId': folderManifestId,
    };
  }

  factory ArchiveStrategyEntry.fromJson(Map<String, dynamic> json) {
    return ArchiveStrategyEntry(
      name: _readRequiredString(json, 'name'),
      archivePath:
          normalizeArchivePath(_readRequiredString(json, 'archivePath')),
      folderManifestId: _readNullableString(json, 'folderManifestId'),
    );
  }
}

class ArchiveThemeProfileEntry {
  const ArchiveThemeProfileEntry({
    required this.id,
    required this.name,
    required this.palette,
    required this.isBuiltIn,
  });

  final String id;
  final String name;
  final MapThemePalette palette;
  final bool isBuiltIn;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'palette': palette.toJson(),
      'isBuiltIn': isBuiltIn,
    };
  }

  factory ArchiveThemeProfileEntry.fromJson(Map<String, dynamic> json) {
    return ArchiveThemeProfileEntry(
      id: _readRequiredString(json, 'id'),
      name: _readRequiredString(json, 'name'),
      palette: MapThemePalette.fromJson(_readRequiredMap(json, 'palette')),
      isBuiltIn: _readRequiredBool(json, 'isBuiltIn'),
    );
  }
}

class ArchiveGlobals {
  const ArchiveGlobals({
    required this.themeProfiles,
    required this.defaultThemeProfileIdForNewStrategies,
    required this.showSpawnBarrier,
    required this.showRegionNames,
    required this.showUltOrbs,
    required this.defaultAgentSizeForNewStrategies,
    required this.defaultAbilitySizeForNewStrategies,
    required this.favoriteAgents,
  });

  final List<ArchiveThemeProfileEntry> themeProfiles;
  final String? defaultThemeProfileIdForNewStrategies;
  final bool showSpawnBarrier;
  final bool showRegionNames;
  final bool showUltOrbs;
  final double defaultAgentSizeForNewStrategies;
  final double defaultAbilitySizeForNewStrategies;
  final List<String> favoriteAgents;

  Map<String, dynamic> toJson() {
    return {
      'themeProfiles':
          themeProfiles.map((profile) => profile.toJson()).toList(),
      'appPreferences': {
        'defaultThemeProfileIdForNewStrategies':
            defaultThemeProfileIdForNewStrategies,
        'showSpawnBarrier': showSpawnBarrier,
        'showRegionNames': showRegionNames,
        'showUltOrbs': showUltOrbs,
        'defaultAgentSizeForNewStrategies': defaultAgentSizeForNewStrategies,
        'defaultAbilitySizeForNewStrategies':
            defaultAbilitySizeForNewStrategies,
      },
      'favoriteAgents': favoriteAgents,
    };
  }

  factory ArchiveGlobals.fromJson(Map<String, dynamic> json) {
    final appPreferences = json['appPreferences'];
    final appPreferencesMap = appPreferences is Map
        ? Map<String, dynamic>.from(appPreferences)
        : null;

    return ArchiveGlobals(
      themeProfiles: _readRequiredList(json, 'themeProfiles')
          .map((entry) => ArchiveThemeProfileEntry.fromJson(
              Map<String, dynamic>.from(entry as Map)))
          .toList(growable: false),
      defaultThemeProfileIdForNewStrategies: appPreferencesMap == null
          ? null
          : _readNullableString(
              appPreferencesMap,
              'defaultThemeProfileIdForNewStrategies',
            ),
      showSpawnBarrier: appPreferencesMap == null
          ? false
          : _readBoolWithDefault(
              appPreferencesMap,
              'showSpawnBarrier',
              false,
            ),
      showRegionNames: appPreferencesMap == null
          ? false
          : _readBoolWithDefault(
              appPreferencesMap,
              'showRegionNames',
              false,
            ),
      showUltOrbs: appPreferencesMap == null
          ? false
          : _readBoolWithDefault(
              appPreferencesMap,
              'showUltOrbs',
              false,
            ),
      defaultAgentSizeForNewStrategies: appPreferencesMap == null
          ? Settings.agentSize
          : _readDoubleWithDefault(
              appPreferencesMap,
              'defaultAgentSizeForNewStrategies',
              Settings.agentSize,
            ),
      defaultAbilitySizeForNewStrategies: appPreferencesMap == null
          ? Settings.abilitySize
          : _readDoubleWithDefault(
              appPreferencesMap,
              'defaultAbilitySizeForNewStrategies',
              Settings.abilitySize,
            ),
      favoriteAgents: _readRequiredList(json, 'favoriteAgents')
          .map((entry) => entry.toString())
          .toList(growable: false),
    );
  }

  Set<AgentType> favoriteAgentTypes() {
    final favorites = <AgentType>{};
    for (final agentName in favoriteAgents) {
      try {
        favorites.add(AgentType.values.byName(agentName));
      } catch (_) {}
    }
    return favorites;
  }
}

bool _readBoolWithDefault(
  Map<String, dynamic> json,
  String key,
  bool fallback,
) {
  final value = json[key];
  return value is bool ? value : fallback;
}

double _readDoubleWithDefault(
  Map<String, dynamic> json,
  String key,
  double fallback,
) {
  final value = json[key];
  if (value is num) {
    return value.toDouble();
  }
  return fallback;
}

class ArchiveManifest {
  const ArchiveManifest({
    required this.schemaVersion,
    required this.archiveType,
    required this.exportedAt,
    required this.appVersionNumber,
    required this.folders,
    required this.strategies,
    required this.globals,
  });

  final int schemaVersion;
  final ArchiveType archiveType;
  final DateTime exportedAt;
  final int appVersionNumber;
  final List<ArchiveFolderEntry> folders;
  final List<ArchiveStrategyEntry> strategies;
  final ArchiveGlobals? globals;

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'archiveType': archiveType.jsonValue,
      'exportedAt': exportedAt.toUtc().toIso8601String(),
      'appVersionNumber': appVersionNumber,
      'folders': folders.map((folder) => folder.toJson()).toList(),
      'strategies': strategies.map((strategy) => strategy.toJson()).toList(),
      if (globals != null) 'globals': globals!.toJson(),
    };
  }

  factory ArchiveManifest.fromJson(Map<String, dynamic> json) {
    final schemaVersion = _readRequiredInt(json, 'schemaVersion');
    if (schemaVersion != archiveManifestSchemaVersion) {
      throw FormatException(
          'Unsupported archive schema version: $schemaVersion');
    }

    return ArchiveManifest(
      schemaVersion: schemaVersion,
      archiveType:
          ArchiveType.fromJsonValue(_readRequiredString(json, 'archiveType')),
      exportedAt:
          DateTime.parse(_readRequiredString(json, 'exportedAt')).toUtc(),
      appVersionNumber: _readRequiredInt(json, 'appVersionNumber'),
      folders: _readRequiredList(json, 'folders')
          .map((entry) => ArchiveFolderEntry.fromJson(
              Map<String, dynamic>.from(entry as Map)))
          .toList(growable: false),
      strategies: _readRequiredList(json, 'strategies')
          .map((entry) => ArchiveStrategyEntry.fromJson(
              Map<String, dynamic>.from(entry as Map)))
          .toList(growable: false),
      globals: json['globals'] == null
          ? null
          : ArchiveGlobals.fromJson(_readRequiredMap(json, 'globals')),
    );
  }
}

String normalizeArchivePath(String value) {
  final normalized = path.posix.normalize(value.replaceAll('\\', '/'));
  if (normalized == '.' || normalized == '/') {
    return '';
  }
  // Strip a leading "./" if present to keep paths relative.
  String sanitized =
      normalized.startsWith('./') ? normalized.substring(2) : normalized;

  // Strip any leading separators so paths like "/foo" cannot remain absolute.
  while (sanitized.startsWith('/')) {
    sanitized = sanitized.substring(1);
  }

  if (sanitized.isEmpty) {
    return '';
  }

  // Reject any attempt at directory traversal.
  final segments = sanitized.split('/');
  if (segments.any((segment) => segment == '..')) {
    throw const FormatException(
        'Path traversal segments ("..") are not allowed in archive paths');
  }

  return sanitized;
}

int _readRequiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }
  throw FormatException('Expected int for $key');
}

int? _readNullableInt(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key) || json[key] == null) {
    return null;
  }
  return _readRequiredInt(json, key);
}

String _readRequiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw FormatException('Expected non-empty string for $key');
}

String _readStringAllowEmpty(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected string for $key');
}

String? _readNullableString(Map<String, dynamic> json, String key) {
  if (!json.containsKey(key) || json[key] == null) {
    return null;
  }
  final value = json[key];
  if (value is String) {
    return value;
  }
  throw FormatException('Expected string or null for $key');
}

bool _readRequiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) {
    return value;
  }
  if (value is String) {
    if (value == 'true') return true;
    if (value == 'false') return false;
  }
  throw FormatException('Expected bool for $key');
}

Map<String, dynamic> _readRequiredMap(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  throw FormatException('Expected map for $key');
}

List<dynamic> _readRequiredList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is List) {
    return value;
  }
  throw FormatException('Expected list for $key');
}
