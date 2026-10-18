import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/config/cloud_startup.dart';
import 'package:icarus/const/hive_boxes.dart';

/// The version of every entry in the copy. An entry at any other version,
/// older or newer, is read as absent: the copy is a cache, never a record.
const cloudStrategyCopyVersion = 1;

/// A copy on this computer of the cloud strategies the signed-in account
/// can open, read when the server can't answer.
///
/// It keeps the server's answers as they were sent (strategy:getShell and
/// page:getSnapshot), so a read goes through the same decoders, and the
/// same corrections, as a live one. Saved work lives on the server and
/// unsent work in the outbox, so deleting any of it loses nothing.
///
/// Each shell and each page is one entry. A write merges row by row and a
/// row only ever moves to a newer revision; element and lineup rows the
/// server deleted stay as the tombstones it sends. A row missing from an
/// answer is dropped only when that answer was asked after the entry's
/// latest answer arrived, so a slow, older answer never removes a row a
/// newer one brought. A page reads back only whole: if any part of it does
/// not decode, the page is not kept.
abstract class CloudStrategyCopyStore implements CloudAccountCopy {
  const CloudStrategyCopyStore();

  String? readEntry(String key);
  Future<void> writeEntry(String key, String value);
  Future<void> deleteEntries(Iterable<String> keys);
  Iterable<String> get entryKeys;

  /// The strategy's shell as last kept, or null when none is kept or it
  /// does not decode.
  RemoteStrategyShell? readShell(CloudCopyScope scope, String strategyId) {
    final answer = _answer(readEntry(_shellKey(scope, strategyId)));
    if (answer == null) return null;
    try {
      final shell = strategyShellFromCopy(ConvexValue.fromDart(answer));
      return shell.header.publicId == strategyId ? shell : null;
    } catch (_) {
      return null;
    }
  }

  /// The page as last kept, or null when it is not kept or any part of it
  /// does not decode.
  RemotePageSnapshot? readPage(
    CloudCopyScope scope,
    String strategyId,
    String pageId,
  ) {
    final raw = readEntry(_pageKey(scope, strategyId, pageId));
    final answer = _answer(raw);
    if (answer == null) return null;
    final arrivedAt = _entry(raw)?['arrivedAt'];
    try {
      final page = pageSnapshotFromCopy(
        ConvexValue.fromDart(answer),
        copiedAt: arrivedAt is num
            ? DateTime.fromMillisecondsSinceEpoch(arrivedAt.toInt())
            : null,
      );
      return page.page.publicId == pageId &&
              page.page.strategyPublicId == strategyId
          ? page
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether the strategy can be opened from the copy: its shell reads, and
  /// at least one of its pages is kept in a format this build reads. Pages
  /// are only decoded when opened, so one that fails then still says so.
  bool keepsStrategy(CloudCopyScope scope, String strategyId) {
    final shell = readShell(scope, strategyId);
    if (shell == null) return false;
    return shell.pages.any((page) =>
        _answer(readEntry(_pageKey(scope, strategyId, page.publicId))) != null);
  }

  /// When the whole strategy was last read into the copy at once (see
  /// [writeFullSnapshot]). Pages kept as the editor read them don't count.
  DateTime? lastFullRefresh(CloudCopyScope scope, String strategyId) {
    final entry = _entry(readEntry(_refreshKey(scope, strategyId)));
    final at = entry?['fullRefreshAt'];
    return at is num ? DateTime.fromMillisecondsSinceEpoch(at.toInt()) : null;
  }

  /// The strategies [scope] keeps anything of.
  Set<String> keptStrategyIds(CloudCopyScope scope) {
    final prefix = scope.storageKeyPrefix;
    return {
      for (final key in entryKeys)
        if (key.startsWith(prefix))
          Uri.decodeComponent(key.substring(prefix.length).split('|').first),
    };
  }

  /// Keeps [answer], a strategy:getShell answer asked at [askedAt].
  Future<void> writeShell(
    CloudCopyScope scope,
    ConvexObject answer, {
    required DateTime askedAt,
    required DateTime arrivedAt,
  }) {
    final incoming = _jsonSafe(answer);
    final strategyId = _string(_map(incoming['header'])['publicId']);
    return _mergeShell(scope, strategyId, incoming);
  }

  /// Keeps [answer], a page:getSnapshot answer of [strategyId] asked at
  /// [askedAt] (for a live read, when it arrived).
  Future<void> writePage(
    CloudCopyScope scope,
    String strategyId,
    ConvexObject answer, {
    required DateTime askedAt,
    required DateTime arrivedAt,
  }) {
    final incoming = _jsonSafe(answer);
    final page = _map(incoming['page']);
    if (page['strategyPublicId'] != strategyId) {
      throw ArgumentError.value(strategyId, 'strategyId', 'not the page\'s');
    }
    return _mergePage(
      scope,
      strategyId,
      _string(page['publicId']),
      incoming,
      askedAt: askedAt,
      arrivedAt: arrivedAt,
    );
  }

  /// Keeps every page of [answer], a strategy:getFullSnapshot answer, and
  /// notes when it arrived (see [lastFullRefresh]).
  Future<void> writeFullSnapshot(
    CloudCopyScope scope,
    ConvexObject answer, {
    required DateTime askedAt,
    required DateTime arrivedAt,
  }) async {
    final full = _jsonSafe(answer);
    final header = _map(full['header']);
    final strategyId = _string(header['publicId']);
    final elements = _list(full['elements']).map(_map).toList();
    final lineups = _list(full['lineups']).map(_map).toList();
    final assets = _list(full['assets']).map(_map).toList();
    final descriptors = <Map<String, dynamic>>[];
    final writes = <Future<void>>[];
    for (final item in _list(full['pages']).map(_map)) {
      final descriptor = Map<String, dynamic>.of(item)
        ..remove('settings')
        ..remove('contentRevision')
        ..remove('contentCreatedAt')
        ..remove('contentUpdatedAt');
      descriptors.add(descriptor);
      final pageId = _string(item['publicId']);
      final pageElements =
          elements.where((row) => row['pagePublicId'] == pageId).toList();
      final pageLineups =
          lineups.where((row) => row['pagePublicId'] == pageId).toList();
      final shown = _stringsShownBy([...pageElements, ...pageLineups]);
      writes.add(_mergePage(
        scope,
        strategyId,
        pageId,
        {
          'page': descriptor,
          'content': {
            'settings': item['settings'],
            'revision': item['contentRevision'],
            'createdAt': item['contentCreatedAt'],
            'updatedAt': item['contentUpdatedAt'],
          },
          'elements': pageElements,
          'lineups': pageLineups,
          'assets': [
            for (final asset in assets)
              if (shown.contains(asset['publicId'])) asset,
          ],
        },
        askedAt: askedAt,
        arrivedAt: arrivedAt,
      ));
    }
    writes.add(
      _mergeShell(scope, strategyId, {'header': header, 'pages': descriptors}),
    );
    writes.add(writeEntry(
      _refreshKey(scope, strategyId),
      jsonEncode({
        'copyVersion': cloudStrategyCopyVersion,
        'fullRefreshAt': arrivedAt.millisecondsSinceEpoch,
      }),
    ));
    await Future.wait(writes);
  }

  Future<void> deleteStrategy(CloudCopyScope scope, String strategyId) {
    final prefix = _strategyPrefix(scope, strategyId);
    return deleteEntries(
      entryKeys.where((key) => key.startsWith(prefix)).toList(),
    );
  }

  /// Deletes everything [scope] keeps, as signing out does. Image files are
  /// not touched.
  @override
  Future<void> deleteAccount(CloudCopyScope scope) {
    final prefix = scope.storageKeyPrefix;
    return deleteEntries(
      entryKeys.where((key) => key.startsWith(prefix)).toList(),
    );
  }

  // Each merge reads the entry and writes the result with no await in
  // between, so two writes of one entry can never interleave.

  Future<void> _mergeShell(
    CloudCopyScope scope,
    String strategyId,
    Map<String, dynamic> incoming,
  ) {
    final key = _shellKey(scope, strategyId);
    final existing = _answer(readEntry(key));
    final merged = _mergedOrIncoming(
      existing,
      incoming,
      () => _mergedShell(existing!, incoming),
    );
    // A page a newer shell no longer lists was deleted, or is in the trash.
    final listsPages = identical(merged, incoming) ||
        _revision(incoming['header']) > _revision(existing?['header']);
    final kept = {
      for (final page in _list(merged['pages'])) _string(_map(page)['publicId'])
    };
    final pagePrefix = '${_strategyPrefix(scope, strategyId)}page|';
    final gone = [
      if (listsPages)
        for (final key in entryKeys)
          if (key.startsWith(pagePrefix) &&
              !kept.contains(
                Uri.decodeComponent(key.substring(pagePrefix.length)),
              ))
            key,
    ];
    return Future.wait([
      writeEntry(key, _encodeEntry(merged)),
      if (gone.isNotEmpty) deleteEntries(gone),
    ]);
  }

  Future<void> _mergePage(
    CloudCopyScope scope,
    String strategyId,
    String pageId,
    Map<String, dynamic> incoming, {
    required DateTime askedAt,
    required DateTime arrivedAt,
  }) {
    final key = _pageKey(scope, strategyId, pageId);
    final raw = readEntry(key);
    final entry = _entry(raw);
    final existing = _answer(raw);
    final previousArrival = (entry?['arrivedAt'] as num?)?.toInt();
    final trustAbsence = previousArrival == null ||
        askedAt.millisecondsSinceEpoch >= previousArrival;
    final merged = _mergedOrIncoming(
      existing,
      incoming,
      () => {
        'page': _newerRow(existing!['page'], incoming['page']),
        'content': _newerRow(existing['content'], incoming['content']),
        'elements': _mergedRows(
          existing['elements'],
          incoming['elements'],
          trustAbsence: trustAbsence,
        ),
        'lineups': _mergedRows(
          existing['lineups'],
          incoming['lineups'],
          trustAbsence: trustAbsence,
        ),
        'assets': _mergedAssets(
          existing['assets'],
          incoming['assets'],
          trustAbsence: trustAbsence,
        ),
      },
    );
    final arrived = arrivedAt.millisecondsSinceEpoch;
    return writeEntry(
      key,
      _encodeEntry(
        merged,
        arrivedAt: previousArrival != null && previousArrival > arrived
            ? previousArrival
            : arrived,
      ),
    );
  }
}

class HiveCloudStrategyCopyStore extends CloudStrategyCopyStore {
  const HiveCloudStrategyCopyStore();

  Box<String> get _box => Hive.box<String>(HiveBoxNames.cloudStrategyCopyBox);

  @override
  String? readEntry(String key) => _box.get(key);

  @override
  Future<void> writeEntry(String key, String value) => _box.put(key, value);

  @override
  Future<void> deleteEntries(Iterable<String> keys) => _box.deleteAll(keys);

  @override
  Iterable<String> get entryKeys => _box.keys.map((key) => key.toString());
}

class MemoryCloudStrategyCopyStore extends CloudStrategyCopyStore {
  MemoryCloudStrategyCopyStore([Map<String, String>? initialValues])
      : values = Map<String, String>.of(initialValues ?? const {});

  final Map<String, String> values;

  @override
  String? readEntry(String key) => values[key];

  @override
  Future<void> writeEntry(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> deleteEntries(Iterable<String> keys) async {
    for (final key in keys.toList()) {
      values.remove(key);
    }
  }

  @override
  Iterable<String> get entryKeys => values.keys;
}

/// The copy where there is none: on web, which needs the network to load,
/// in a run where cloud sync did not start, or when the box would not open.
/// It keeps nothing and reads nothing.
class UnavailableCloudStrategyCopyStore extends CloudStrategyCopyStore {
  const UnavailableCloudStrategyCopyStore();

  @override
  String? readEntry(String key) => null;

  @override
  Future<void> writeEntry(String key, String value) async {}

  @override
  Future<void> deleteEntries(Iterable<String> keys) async {}

  @override
  Iterable<String> get entryKeys => const [];
}

final cloudStrategyCopyStoreProvider = Provider<CloudStrategyCopyStore>((ref) {
  final cloudStarted = ref.watch(cloudStartupProvider).isAvailable;
  return cloudStarted && Hive.isBoxOpen(HiveBoxNames.cloudStrategyCopyBox)
      ? const HiveCloudStrategyCopyStore()
      : const UnavailableCloudStrategyCopyStore();
});

/// [merge] of the kept [existing] answer with [incoming], or [incoming]
/// alone when nothing is kept or what is kept can't be merged.
Map<String, dynamic> _mergedOrIncoming(
  Map<String, dynamic>? existing,
  Map<String, dynamic> incoming,
  Map<String, dynamic> Function() merge,
) {
  if (existing == null) return incoming;
  try {
    return merge();
  } catch (_) {
    return incoming;
  }
}

String _strategyPrefix(CloudCopyScope scope, String strategyId) =>
    '${scope.storageKeyPrefix}${Uri.encodeComponent(strategyId)}|';

String _shellKey(CloudCopyScope scope, String strategyId) =>
    '${_strategyPrefix(scope, strategyId)}shell';

String _pageKey(CloudCopyScope scope, String strategyId, String pageId) =>
    '${_strategyPrefix(scope, strategyId)}page|${Uri.encodeComponent(pageId)}';

String _refreshKey(CloudCopyScope scope, String strategyId) =>
    '${_strategyPrefix(scope, strategyId)}refresh';

String _encodeEntry(Map<String, dynamic> answer, {int? arrivedAt}) =>
    jsonEncode({
      'copyVersion': cloudStrategyCopyVersion,
      if (arrivedAt != null) 'arrivedAt': arrivedAt,
      'answer': answer,
    });

/// The entry in [raw], or null when there is none or it is not one this
/// build reads.
Map<String, dynamic>? _entry(String? raw) {
  if (raw == null) return null;
  try {
    final entry = jsonDecode(raw);
    if (entry is! Map<String, dynamic>) return null;
    return entry['copyVersion'] == cloudStrategyCopyVersion ? entry : null;
  } on FormatException {
    return null;
  }
}

Map<String, dynamic>? _answer(String? raw) {
  final answer = _entry(raw)?['answer'];
  return answer is Map<String, dynamic> ? answer : null;
}

Map<String, dynamic> _jsonSafe(ConvexObject answer) =>
    jsonDecode(jsonEncode(answer.toDart())) as Map<String, dynamic>;

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  throw const FormatException('Expected an object in a kept answer');
}

List<Object?> _list(Object? value) {
  if (value is List) return value;
  throw const FormatException('Expected a list in a kept answer');
}

String _string(Object? value) {
  if (value is String) return value;
  throw const FormatException('Expected a string in a kept answer');
}

num _revision(Object? row) {
  final revision = row is Map ? row['revision'] : null;
  return revision is num ? revision : -1;
}

/// [incoming] unless [existing] has the higher revision.
Object? _newerRow(Object? existing, Object? incoming) =>
    _revision(incoming) >= _revision(existing) ? incoming : existing;

Map<String, dynamic> _mergedShell(
  Map<String, dynamic> existing,
  Map<String, dynamic> incoming,
) {
  // Adding, deleting and moving a page each bump the strategy's revision,
  // so the newer header says which pages there are and in what order.
  final incomingIsNewer =
      _revision(incoming['header']) >= _revision(existing['header']);
  final existingPages = _byPublicId(existing['pages']);
  final incomingPages = _byPublicId(incoming['pages']);
  final listed = incomingIsNewer ? incoming['pages'] : existing['pages'];
  return {
    'header': _newerRow(existing['header'], incoming['header']),
    'pages': [
      for (final page in _list(listed))
        _newerRow(
          existingPages[_map(page)['publicId']],
          incomingPages[_map(page)['publicId']],
        ),
    ],
  };
}

Map<Object?, Object?> _byPublicId(Object? rows) =>
    {for (final row in _list(rows)) _map(row)['publicId']: row};

List<Object?> _mergedRows(
  Object? existing,
  Object? incoming, {
  required bool trustAbsence,
}) {
  final merged = trustAbsence
      ? <Object?, Object?>{}
      : Map<Object?, Object?>.of(_byPublicId(existing));
  final previous = _byPublicId(existing);
  for (final row in _list(incoming)) {
    final id = _map(row)['publicId'];
    merged[id] = _newerRow(previous[id], row);
  }
  final rows = merged.values.toList();
  rows.sort((left, right) {
    final bySort = (_map(left)['sortIndex'] as num)
        .compareTo(_map(right)['sortIndex'] as num);
    if (bySort != 0) return bySort;
    return _string(_map(left)['publicId'])
        .compareTo(_string(_map(right)['publicId']));
  });
  return rows;
}

List<Object?> _mergedAssets(
  Object? existing,
  Object? incoming, {
  required bool trustAbsence,
}) {
  final merged = trustAbsence
      ? <Object?, Object?>{}
      : Map<Object?, Object?>.of(_byPublicId(existing));
  for (final asset in _list(incoming)) {
    merged[_map(asset)['publicId']] = asset;
  }
  final assets = merged.values.toList()
    ..sort((left, right) => _string(_map(left)['publicId'])
        .compareTo(_string(_map(right)['publicId'])));
  return assets;
}

/// Every string in the payloads of [rows] that the server has not deleted.
/// An image asset a page shows is named by one of them: a placed image's
/// own id or picture id, or a lineup image's id.
Set<String> _stringsShownBy(Iterable<Map<String, dynamic>> rows) {
  final strings = <String>{};
  void collect(Object? value) {
    if (value is String) {
      strings.add(value);
    } else if (value is Map) {
      value.values.forEach(collect);
    } else if (value is List) {
      value.forEach(collect);
    }
  }

  for (final row in rows) {
    if (row['deleted'] == true) continue;
    collect(row['payload']);
  }
  return strings;
}
