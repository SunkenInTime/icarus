import 'package:flutter/painting.dart' show Offset;
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus_library/icarus_library.dart';

import 'shadow_copy_test.dart' show handBuilt;

const strategyId = 'hand-1';
const pageId = 'p1';
final at = DateTime.utc(2026, 11, 1);
final servedAccount = Account('account-a');

StrategyRowSet serverRows({Offset agentAt = const Offset(10, 20)}) =>
    switch (strategyToRows(handBuilt(agentAt: agentAt))) {
      StrategyRowsMade(:final rows) => rows,
      StrategyRowsRefused(:final problems) => throw StateError('$problems'),
    };

Map<String, Object?> _json(Row row) => row.toJson()! as Map<String, Object?>;

RemotePage _remotePage(PageRow row) {
  final fields = _json(row);
  return RemotePage(
    publicId: row.publicId,
    strategyPublicId: fields['strategyPublicId']! as String,
    name: fields['name']! as String,
    isAutoNamed: fields['isAutoNamed'] as bool?,
    sortIndex: fields['sortIndex']! as int,
    isAttack: fields['isAttack']! as bool,
    revision: fields['revision']! as int,
    createdAt: at,
    updatedAt: at,
  );
}

RemotePageContent _remoteContent(StrategyRowSet rows, String page) {
  final fields = _json(rows.settingsOf(page)!);
  return RemotePageContent(
    settings: fields['settings'] as Map<String, dynamic>?,
    revision: fields['revision']! as int,
    createdAt: at,
    updatedAt: at,
  );
}

RemotePageList pageList(
  StrategyRowSet rows, {
  int revision = 1,
  RemotePageContent? content,
  List<RemoteFullPage> more = const [],
  bool withOpenPage = true,
}) {
  final strategy = _json(rows.strategy);
  return RemotePageList(
    header: RemoteStrategyHeader(
      publicId: strategyId,
      name: strategy['name']! as String,
      mapData: strategy['mapData']! as String,
      revision: revision,
      createdAt: at,
      updatedAt: at,
      role: 'owner',
    ),
    pages: [
      if (withOpenPage)
        for (final page in rows.pages)
          RemoteFullPage(
            page: _remotePage(page),
            content: content ?? _remoteContent(rows, page.publicId),
          ),
      ...more,
    ],
  );
}

RemotePageSnapshot pageSnapshot(
  StrategyRowSet rows, {
  RemotePageContent? content,
}) =>
    RemotePageSnapshot(
      page: _remotePage(rows.page(pageId)!),
      content: content ?? _remoteContent(rows, pageId),
      elements: [
        for (final element in rows.elementsOn(pageId))
          RemoteElement(
            publicId: element.publicId,
            strategyPublicId: strategyId,
            pagePublicId: pageId,
            elementType: (_json(element)['payload']! as Map)['kind']! as String,
            payload: Map<String, dynamic>.from(
              _json(element)['payload']! as Map,
            ),
            sortIndex: _json(element)['sortIndex']! as int,
            revision: _json(element)['revision']! as int,
            deleted: _json(element)['deleted']! as bool,
            createdAt: at,
          ),
      ],
      lineups: const [],
      assetsById: const {},
    );

Future<LibraryStore> openStore(MemoryStorage storage) async =>
    switch (await LibraryStore.open(
      MemoryEngine(storage),
      canRead: appCanRead,
      build: 'test-build',
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

RemoteFullPage secondPage() => RemoteFullPage(
      page: RemotePage(
        publicId: 'p2',
        strategyPublicId: strategyId,
        name: 'Page 2',
        sortIndex: 1,
        isAttack: false,
        revision: 1,
        createdAt: at,
        updatedAt: at,
      ),
      content: RemotePageContent(
        settings: {
          'agentSize': 40.0,
          'abilitySize': 30.0,
          'useNeutralTeamColors': false,
        },
        revision: 1,
        createdAt: at,
        updatedAt: at,
      ),
    );
