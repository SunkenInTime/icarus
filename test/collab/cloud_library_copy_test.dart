import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_library_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';

const _scope = CloudCopyScope(
  deploymentUrl: 'https://prod-1.convex.cloud',
  accountId: 'user-a',
);

CloudFolderEntry _folder(String id, {String? parentId, String role = 'owner'}) {
  return (
    folder: Folder(
      id: id,
      name: 'Folder $id',
      dateCreated: DateTime(2026, 10, 1, 9, 30),
      parentID: parentId,
      iconId: 3,
      color: FolderColor.custom,
      customColor: const Color(0xff123456),
    ),
    role: role,
    strategyCount: 4,
    mapPeeks: const [MapValue.haven, MapValue.ascent],
    agentTypes: const [AgentType.sova, AgentType.jett],
  );
}

CloudStrategyEntry _strategy(String id, {String? folderId}) {
  return (
    strategy: StrategyData(
      id: id,
      name: 'Strategy $id',
      mapData: MapValue.lotus,
      versionNumber: 1,
      lastEdited: DateTime(2026, 10, 17, 14, 32),
      createdAt: DateTime(2026, 10, 2),
      folderID: folderId,
      themeProfileId: 'profile-1',
      themeOverridePalette: MapThemePalette(
        baseColorValue: 0xff112233,
        detailColorValue: 0xff445566,
        highlightColorValue: 0xff778899,
      ),
    ),
    revision: 7,
    role: 'editor',
    attackLabel: 'Defense',
  );
}

void main() {
  late MemoryCloudLibraryCopyStore store;
  final matchedAt = DateTime(2026, 10, 17, 14, 32);

  setUp(() => store = MemoryCloudLibraryCopyStore());

  test('folders read back in every field the list shows', () async {
    await store.writeFolders(
      _scope,
      [_folder('f1'), _folder('f2', parentId: 'f1', role: 'viewer')],
      matchedAt: matchedAt,
    );

    final copy = store.readFolders(_scope)!;
    expect(copy.matchedAt, matchedAt);
    final first = copy.entries.first;
    expect(first.folder.id, 'f1');
    expect(first.folder.name, 'Folder f1');
    expect(first.folder.dateCreated, DateTime(2026, 10, 1, 9, 30));
    expect(first.folder.parentID, isNull);
    expect(first.folder.iconId, 3);
    expect(first.folder.color, FolderColor.custom);
    expect(first.folder.customColor?.toARGB32(), 0xff123456);
    expect(first.role, 'owner');
    expect(first.strategyCount, 4);
    expect(first.mapPeeks, [MapValue.haven, MapValue.ascent]);
    expect(first.agentTypes, [AgentType.sova, AgentType.jett]);
    expect(copy.entries.last.folder.parentID, 'f1');
    expect(copy.entries.last.role, 'viewer');
  });

  test('strategies read back in every field the list shows', () async {
    const listing = CloudStrategyListing.shared('f1');
    await store.writeStrategies(
      _scope,
      listing,
      [_strategy('s1', folderId: 'f1')],
      matchedAt: matchedAt,
    );

    expect(
      store.readStrategies(_scope, const CloudStrategyListing.owned('f1')),
      isNull,
    );
    final entry = store.readStrategies(_scope, listing)!.entries.single;
    expect(entry.strategy.id, 's1');
    expect(entry.strategy.name, 'Strategy s1');
    expect(entry.strategy.mapData, MapValue.lotus);
    expect(entry.strategy.lastEdited, DateTime(2026, 10, 17, 14, 32));
    expect(entry.strategy.createdAt, DateTime(2026, 10, 2));
    expect(entry.strategy.folderID, 'f1');
    expect(entry.strategy.themeProfileId, 'profile-1');
    expect(
      entry.strategy.themeOverridePalette?.toJson(),
      _strategy('s1').strategy.themeOverridePalette!.toJson(),
    );
    expect(entry.revision, 7);
    expect(entry.role, 'editor');
    expect(entry.attackLabel, 'Defense');
  });

  test('records survive a JSON round trip, the way Hive stores them', () async {
    await store.writeStrategies(
      _scope,
      const CloudStrategyListing.owned(null),
      [_strategy('s1')],
      matchedAt: matchedAt,
    );
    final reloaded = MemoryCloudLibraryCopyStore({
      for (final entry in store.values.entries)
        entry.key: jsonDecode(jsonEncode(entry.value)),
    });

    expect(
      reloaded
          .readStrategies(_scope, const CloudStrategyListing.owned(null))!
          .entries
          .single
          .strategy
          .id,
      's1',
    );
  });

  test('a record with one unreadable entry is absent, not partly shown',
      () async {
    const listing = CloudStrategyListing.owned(null);
    await store.writeStrategies(
      _scope,
      listing,
      [_strategy('s1'), _strategy('s2')],
      matchedAt: matchedAt,
    );
    final key = store.values.keys.single;
    final record = Map<String, dynamic>.from(store.values[key]! as Map);
    final entries = [...record['entries'] as List];
    entries[1] = {...entries[1] as Map, 'mapData': 'a-map-from-the-future'};
    store.values[key] = {...record, 'entries': entries};

    expect(store.readStrategies(_scope, listing), isNull);
  });

  test('a record in another format is absent', () async {
    await store.writeFolders(_scope, [_folder('f1')], matchedAt: matchedAt);
    final key = store.values.keys.single;
    store.values[key] = {
      ...store.values[key]! as Map<String, dynamic>,
      'copyVersion': cloudLibraryCopyRecordVersion + 1,
    };

    expect(store.readFolders(_scope), isNull);
  });

  test('another deployment or account never reads this copy', () async {
    await store.writeFolders(_scope, [_folder('f1')], matchedAt: matchedAt);

    expect(
      store.readFolders(const CloudCopyScope(
        deploymentUrl: 'https://dev-1.convex.cloud',
        accountId: 'user-a',
      )),
      isNull,
    );
    expect(
      store.readFolders(const CloudCopyScope(
        deploymentUrl: 'https://prod-1.convex.cloud',
        accountId: 'user-b',
      )),
      isNull,
    );
  });

  test("deleteAccount removes that account's records and no one else's",
      () async {
    const other = CloudCopyScope(
      deploymentUrl: 'https://prod-1.convex.cloud',
      accountId: 'user-b',
    );
    await store.writeFolders(_scope, [_folder('f1')], matchedAt: matchedAt);
    await store.writeStrategies(
      _scope,
      const CloudStrategyListing.owned('f1'),
      [_strategy('s1')],
      matchedAt: matchedAt,
    );
    await store.writeFolders(other, [_folder('g1')], matchedAt: matchedAt);

    await store.deleteAccount(_scope);

    expect(store.readFolders(_scope), isNull);
    expect(
      store.readStrategies(_scope, const CloudStrategyListing.owned('f1')),
      isNull,
    );
    expect(store.readFolders(other), isNotNull);
    expect(store.values, hasLength(1));
  });

  test('a new folder tree drops the lists of folders no longer in it',
      () async {
    await store.writeFolders(
      _scope,
      [_folder('f1'), _folder('f2')],
      matchedAt: matchedAt,
    );
    for (final listing in const [
      CloudStrategyListing.owned(null),
      CloudStrategyListing.owned('f1'),
      CloudStrategyListing.owned('f2'),
      CloudStrategyListing.shared(null),
      CloudStrategyListing.shared('f2'),
    ]) {
      await store.writeStrategies(
        _scope,
        listing,
        [_strategy('s')],
        matchedAt: matchedAt,
      );
    }

    await store.writeFolders(_scope, [_folder('f1')], matchedAt: matchedAt);

    bool kept(CloudStrategyListing listing) =>
        store.readStrategies(_scope, listing) != null;
    expect(kept(const CloudStrategyListing.owned(null)), isTrue);
    expect(kept(const CloudStrategyListing.owned('f1')), isTrue);
    expect(kept(const CloudStrategyListing.shared(null)), isTrue);
    expect(kept(const CloudStrategyListing.owned('f2')), isFalse);
    expect(kept(const CloudStrategyListing.shared('f2')), isFalse);
  });

  test('marking a record matched moves its time forward only', () async {
    await store.writeFolders(_scope, [_folder('f1')], matchedAt: matchedAt);
    final later = matchedAt.add(const Duration(hours: 3));

    await store.markFoldersMatched(_scope, later);
    expect(store.readFolders(_scope)!.matchedAt, later);

    await store.markFoldersMatched(_scope, matchedAt);
    expect(store.readFolders(_scope)!.matchedAt, later);
    expect(store.readFolders(_scope)!.entries.single.folder.id, 'f1');
  });

  test('marking a record that was never written writes nothing', () async {
    await store.markStrategiesMatched(
      _scope,
      const CloudStrategyListing.owned(null),
      matchedAt,
    );
    expect(store.values, isEmpty);
  });
}
