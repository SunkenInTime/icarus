import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/config/cloud_build_config.dart';
import 'package:icarus/config/cloud_startup.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

/// The format of a record in [HiveBoxNames.cloudLibraryCopyBox]. A record
/// in any other format, a newer one included, reads as absent: the copy is
/// a cache, and the next live answer replaces it.
const cloudLibraryCopyRecordVersion = 1;

/// Whose copy a record is: one Convex deployment and one account. Dev and
/// production builds share the sign-in on a computer, so neither may read
/// the other's copy.
class CloudCopyScope {
  const CloudCopyScope({required this.deploymentUrl, required this.accountId});

  final String deploymentUrl;
  final String accountId;

  /// Every key of this scope's records starts with this.
  String get storageKeyPrefix => '${Uri.encodeComponent(deploymentUrl)}|'
      '${Uri.encodeComponent(accountId)}|';

  @override
  bool operator ==(Object other) =>
      other is CloudCopyScope &&
      other.deploymentUrl == deploymentUrl &&
      other.accountId == accountId;

  @override
  int get hashCode => Object.hash(deploymentUrl, accountId);
}

/// One of the strategy lists the library reads: My Library's own
/// strategies at the top level or in a folder, or what is shared with the
/// user at the top of Shared or inside a shared folder.
class CloudStrategyListing {
  const CloudStrategyListing.owned(this.folderId) : shared = false;
  const CloudStrategyListing.shared(this.folderId) : shared = true;

  final bool shared;

  /// Null is the top level.
  final String? folderId;

  String get _storageKey => '$_strategiesKey${shared ? 'shared' : 'owned'}|'
      '${folderId == null ? '' : Uri.encodeComponent(folderId!)}';

  @override
  bool operator ==(Object other) =>
      other is CloudStrategyListing &&
      other.shared == shared &&
      other.folderId == folderId;

  @override
  int get hashCode => Object.hash(shared, folderId);
}

/// A list as the server last gave it, and when it last matched the server.
class CloudLibraryCopy<T> {
  const CloudLibraryCopy({required this.entries, required this.matchedAt});

  final List<T> entries;
  final DateTime matchedAt;
}

/// Something kept on this computer per deployment and account, removed
/// when that account signs out.
abstract interface class CloudAccountCopy {
  Future<void> deleteAccount(CloudCopyScope scope);
}

/// The library list kept on this computer: the folder tree and the
/// strategy lists the library has read, each exactly as the last live answer
/// gave it. A cache, never a record: what the user saved lives on the
/// server, so a record that is missing or doesn't read back is absent, and
/// deleting any of it loses nothing.
abstract class CloudLibraryCopyStore implements CloudAccountCopy {
  /// Whether this run keeps a copy at all (desktop, with the box open).
  bool get keepsCopy;

  CloudLibraryCopy<CloudFolderEntry>? readFolders(CloudCopyScope scope);

  CloudLibraryCopy<CloudStrategyEntry>? readStrategies(
    CloudCopyScope scope,
    CloudStrategyListing listing,
  );

  /// Replaces the folder tree, and drops the strategy lists of folders that
  /// are no longer in it.
  Future<void> writeFolders(
    CloudCopyScope scope,
    List<CloudFolderEntry> folders, {
    required DateTime matchedAt,
  });

  Future<void> writeStrategies(
    CloudCopyScope scope,
    CloudStrategyListing listing,
    List<CloudStrategyEntry> strategies, {
    required DateTime matchedAt,
  });

  /// Records that the kept folder tree still matched the server at [at]
  /// (the live answer held until then without changing).
  Future<void> markFoldersMatched(CloudCopyScope scope, DateTime at);

  Future<void> markStrategiesMatched(
    CloudCopyScope scope,
    CloudStrategyListing listing,
    DateTime at,
  );
}

const _foldersKey = 'folders';
const _strategiesKey = 'strategies|';

/// The record logic over any string-keyed map of JSON values.
abstract class _KeyedCloudLibraryCopyStore implements CloudLibraryCopyStore {
  Iterable<String> get _keys;
  Object? _get(String key);
  Future<void> _put(String key, Map<String, dynamic> value);
  Future<void> _deleteAll(Iterable<String> keys);

  @override
  bool get keepsCopy => true;

  @override
  CloudLibraryCopy<CloudFolderEntry>? readFolders(CloudCopyScope scope) {
    return _read(
      scope,
      _foldersKey,
      kind: 'folders',
      decode: cloudFolderEntryFromCopyJson,
    );
  }

  @override
  CloudLibraryCopy<CloudStrategyEntry>? readStrategies(
    CloudCopyScope scope,
    CloudStrategyListing listing,
  ) {
    return _read(
      scope,
      listing._storageKey,
      kind: 'strategies',
      decode: cloudStrategyEntryFromCopyJson,
    );
  }

  @override
  Future<void> writeFolders(
    CloudCopyScope scope,
    List<CloudFolderEntry> folders, {
    required DateTime matchedAt,
  }) async {
    await _put(
      scope.storageKeyPrefix + _foldersKey,
      _record(
        scope,
        kind: 'folders',
        matchedAt: matchedAt,
        entries: [
          for (final entry in folders) cloudFolderEntryToCopyJson(entry)
        ],
      ),
    );
    final folderIds = {
      for (final entry in folders) Uri.encodeComponent(entry.folder.id),
    };
    final listingsPrefix = scope.storageKeyPrefix + _strategiesKey;
    await _deleteAll([
      for (final key in _keys)
        if (key.startsWith(listingsPrefix))
          if (key.substring(key.lastIndexOf('|') + 1) case final folderId
              when folderId.isNotEmpty && !folderIds.contains(folderId))
            key,
    ]);
  }

  @override
  Future<void> writeStrategies(
    CloudCopyScope scope,
    CloudStrategyListing listing,
    List<CloudStrategyEntry> strategies, {
    required DateTime matchedAt,
  }) {
    return _put(
      scope.storageKeyPrefix + listing._storageKey,
      _record(
        scope,
        kind: 'strategies',
        matchedAt: matchedAt,
        entries: [
          for (final entry in strategies) cloudStrategyEntryToCopyJson(entry),
        ],
      ),
    );
  }

  @override
  Future<void> markFoldersMatched(CloudCopyScope scope, DateTime at) =>
      _markMatched(scope.storageKeyPrefix + _foldersKey, at);

  @override
  Future<void> markStrategiesMatched(
    CloudCopyScope scope,
    CloudStrategyListing listing,
    DateTime at,
  ) =>
      _markMatched(scope.storageKeyPrefix + listing._storageKey, at);

  @override
  Future<void> deleteAccount(CloudCopyScope scope) {
    final prefix = scope.storageKeyPrefix;
    return _deleteAll([
      for (final key in _keys)
        if (key.startsWith(prefix)) key,
    ]);
  }

  Map<String, dynamic> _record(
    CloudCopyScope scope, {
    required String kind,
    required DateTime matchedAt,
    required List<Map<String, dynamic>> entries,
  }) =>
      <String, dynamic>{
        'copyVersion': cloudLibraryCopyRecordVersion,
        'deploymentUrl': scope.deploymentUrl,
        'accountId': scope.accountId,
        'kind': kind,
        'matchedAt': matchedAt.toUtc().toIso8601String(),
        'entries': entries,
      };

  Future<void> _markMatched(String key, DateTime at) async {
    final json = _object(_get(key));
    if (json == null) return;
    final matchedAt = DateTime.tryParse('${json['matchedAt']}');
    if (matchedAt != null && !at.isAfter(matchedAt)) return;
    await _put(key, {...json, 'matchedAt': at.toUtc().toIso8601String()});
  }

  /// Whole or not at all: one entry that doesn't read back makes the record
  /// absent, rather than show a list with something silently missing.
  CloudLibraryCopy<T>? _read<T>(
    CloudCopyScope scope,
    String key, {
    required String kind,
    required T Function(Map<String, dynamic> json) decode,
  }) {
    try {
      final json = _object(_get(scope.storageKeyPrefix + key));
      if (json == null ||
          json['copyVersion'] != cloudLibraryCopyRecordVersion ||
          json['deploymentUrl'] != scope.deploymentUrl ||
          json['accountId'] != scope.accountId ||
          json['kind'] != kind) {
        return null;
      }
      final matchedAt = DateTime.parse(json['matchedAt'] as String).toLocal();
      return CloudLibraryCopy(
        entries: [
          for (final entry in json['entries'] as List) decode(_object(entry)!),
        ],
        matchedAt: matchedAt,
      );
    } catch (_) {
      return null;
    }
  }
}

Map<String, dynamic>? _object(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

class HiveCloudLibraryCopyStore extends _KeyedCloudLibraryCopyStore {
  Box<dynamic> get _box => Hive.box<dynamic>(HiveBoxNames.cloudLibraryCopyBox);

  @override
  Iterable<String> get _keys => _box.keys.map((key) => key.toString());

  @override
  Object? _get(String key) => _box.get(key);

  @override
  Future<void> _put(String key, Map<String, dynamic> value) =>
      _box.put(key, value);

  @override
  Future<void> _deleteAll(Iterable<String> keys) => _box.deleteAll(keys);
}

class MemoryCloudLibraryCopyStore extends _KeyedCloudLibraryCopyStore {
  MemoryCloudLibraryCopyStore([Map<String, Object?>? initialValues])
      : values = Map<String, Object?>.from(initialValues ?? const {});

  final Map<String, Object?> values;

  @override
  Iterable<String> get _keys => values.keys;

  @override
  Object? _get(String key) => values[key];

  @override
  Future<void> _put(String key, Map<String, dynamic> value) async {
    values[key] = value;
  }

  @override
  Future<void> _deleteAll(Iterable<String> keys) async {
    for (final key in keys.toList()) {
      values.remove(key);
    }
  }
}

/// No copy: on web, where the app needs the network to load at all, and in
/// a run where the box could not be opened or cloud sync did not start.
/// Reads find nothing and writes keep nothing.
class UnavailableCloudLibraryCopyStore implements CloudLibraryCopyStore {
  const UnavailableCloudLibraryCopyStore();

  @override
  bool get keepsCopy => false;

  @override
  CloudLibraryCopy<CloudFolderEntry>? readFolders(CloudCopyScope scope) => null;

  @override
  CloudLibraryCopy<CloudStrategyEntry>? readStrategies(
    CloudCopyScope scope,
    CloudStrategyListing listing,
  ) =>
      null;

  @override
  Future<void> writeFolders(
    CloudCopyScope scope,
    List<CloudFolderEntry> folders, {
    required DateTime matchedAt,
  }) async {}

  @override
  Future<void> writeStrategies(
    CloudCopyScope scope,
    CloudStrategyListing listing,
    List<CloudStrategyEntry> strategies, {
    required DateTime matchedAt,
  }) async {}

  @override
  Future<void> markFoldersMatched(CloudCopyScope scope, DateTime at) async {}

  @override
  Future<void> markStrategiesMatched(
    CloudCopyScope scope,
    CloudStrategyListing listing,
    DateTime at,
  ) async {}

  @override
  Future<void> deleteAccount(CloudCopyScope scope) async {}
}

/// Opens [HiveBoxNames.cloudLibraryCopyBox] and returns whether it is open.
/// A box that won't open is deleted and opened empty: it is a cache, and
/// losing it costs only the next live read. It never throws, so the copy can
/// never keep the cloud from starting.
Future<bool> openCloudLibraryCopyBox() async {
  try {
    await Hive.openBox<dynamic>(HiveBoxNames.cloudLibraryCopyBox);
    return true;
  } catch (_) {}
  try {
    await Hive.deleteBoxFromDisk(HiveBoxNames.cloudLibraryCopyBox);
    await Hive.openBox<dynamic>(HiveBoxNames.cloudLibraryCopyBox);
    return true;
  } catch (_) {
    return false;
  }
}

final cloudLibraryCopyStoreProvider = Provider<CloudLibraryCopyStore>((ref) {
  if (!ref.watch(cloudStartupProvider).isAvailable ||
      !Hive.isBoxOpen(HiveBoxNames.cloudLibraryCopyBox)) {
    return const UnavailableCloudLibraryCopyStore();
  }
  return HiveCloudLibraryCopyStore();
});

/// The deployment this build talks to, the first half of every
/// [CloudCopyScope].
final cloudCopyDeploymentUrlProvider = Provider<String>((ref) {
  return CloudBuildConfig.fromEnvironment(isReleaseMode: kReleaseMode)
      .deploymentUrl;
});

/// Everything kept on this computer per account, so signing out can remove
/// all of it. The strategy copy registers here beside the library copy.
final cloudAccountCopiesProvider = Provider<List<CloudAccountCopy>>((ref) {
  return [ref.watch(cloudLibraryCopyStoreProvider)];
});

// The entries, in the fields the library list reads (see
// CloudFolderEntry and CloudStrategyEntry). Maps and agents are kept by
// their wire names, the way the server sends them.

Map<String, dynamic> cloudFolderEntryToCopyJson(CloudFolderEntry entry) {
  final folder = entry.folder;
  return <String, dynamic>{
    'id': folder.id,
    'name': folder.name,
    'createdAt': folder.dateCreated.toUtc().toIso8601String(),
    'parentId': folder.parentID,
    'iconId': folder.iconId,
    'color': folder.color.name,
    'customColor': folder.customColor?.toARGB32(),
    'role': entry.role,
    'strategyCount': entry.strategyCount,
    'mapPeeks': [
      for (final map in entry.mapPeeks)
        if (Maps.mapNames[map] case final wireName?) wireName,
    ],
    'agentTypes': [for (final type in entry.agentTypes) type.name],
  };
}

CloudFolderEntry cloudFolderEntryFromCopyJson(Map<String, dynamic> json) {
  return (
    folder: Folder(
      id: json['id'] as String,
      name: json['name'] as String,
      dateCreated: DateTime.parse(json['createdAt'] as String).toLocal(),
      parentID: json['parentId'] as String?,
      iconId: folderIconIdFromCloud(
        iconId: (json['iconId'] as num?)?.toInt(),
        codePoint: null,
        fontFamily: null,
        fontPackage: null,
      ),
      color: folderColorFromWireName(json['color'] as String?),
      customColor:
          folderCustomColorFromCloud((json['customColor'] as num?)?.toInt()),
    ),
    role: json['role'] as String,
    strategyCount: (json['strategyCount'] as num).toInt(),
    mapPeeks: [
      for (final wireName in json['mapPeeks'] as List)
        if (_mapValueOrNull(wireName as String) case final map?) map,
    ],
    agentTypes: [
      for (final name in json['agentTypes'] as List)
        if (_agentTypeOrNull(name as String) case final type?) type,
    ],
  );
}

Map<String, dynamic> cloudStrategyEntryToCopyJson(CloudStrategyEntry entry) {
  final strategy = entry.strategy;
  return <String, dynamic>{
    'id': strategy.id,
    'name': strategy.name,
    'mapData': Maps.mapNames[strategy.mapData],
    'updatedAt': strategy.lastEdited.toUtc().toIso8601String(),
    'createdAt': strategy.createdAt.toUtc().toIso8601String(),
    'folderId': strategy.folderID,
    'themeProfileId': strategy.themeProfileId,
    'themeOverridePalette': strategy.themeOverridePalette?.toJson(),
    'revision': entry.revision,
    'role': entry.role,
    'attackLabel': entry.attackLabel,
  };
}

CloudStrategyEntry cloudStrategyEntryFromCopyJson(Map<String, dynamic> json) {
  final mapData = _mapValueOrNull(json['mapData'] as String);
  if (mapData == null) {
    throw FormatException('Unknown map ${json['mapData']}');
  }
  final palette = _object(json['themeOverridePalette']);
  return (
    strategy: StrategyData(
      id: json['id'] as String,
      name: json['name'] as String,
      mapData: mapData,
      versionNumber: Settings.versionNumber,
      lastEdited: DateTime.parse(json['updatedAt'] as String).toLocal(),
      createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
      folderID: json['folderId'] as String?,
      themeProfileId: json['themeProfileId'] as String?,
      themeOverridePalette:
          palette == null ? null : MapThemePalette.fromJson(palette),
    ),
    revision: (json['revision'] as num).toInt(),
    role: json['role'] as String,
    attackLabel: json['attackLabel'] as String,
  );
}

MapValue? _mapValueOrNull(String wireName) {
  for (final entry in Maps.mapNames.entries) {
    if (entry.value == wireName) return entry.key;
  }
  return null;
}

AgentType? _agentTypeOrNull(String name) {
  for (final type in AgentType.values) {
    if (type.name == name) return type;
  }
  return null;
}
