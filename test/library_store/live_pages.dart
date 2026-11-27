import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus_library/icarus_library.dart';

import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

const openPage = ReadOfPage(pageId);
const heavyItems = 3000;

Map<String, Object?> jsonOf(Row row) => row.toJson()! as Map<String, Object?>;

DateTime lifeOf(Row row) =>
    DateTime.fromMillisecondsSinceEpoch(createdAtOf(row)!, isUtc: true);

ElementRow elementFrom(Map<String, Object?> json) =>
    switch (ElementRow.decode(json, canRead: appCanRead.element)) {
      Read(:final value) => value,
      CouldNotRead(:final problem) => throw StateError(problem),
    };

void fillServerPage(World world, int items) {
  final rows = world.server.rows[strategyId]!;
  final on = rows.elementsOn(pageId).toList();
  final first = jsonOf(on.first)..remove('createdAt');
  world.server.rows[strategyId] = rows.withRows([
    for (var n = on.length; n < items; n++)
      elementFrom({
        ...first,
        'publicId': 'fill-${n.toString().padLeft(5, '0')}',
        'sortIndex': 100 + n,
        'revision': 1,
      }),
  ]);
}

void unreadableOnServer(World world, String id) {
  final rows = world.server.rows[strategyId]!;
  final first = jsonOf(rows.elementsOn(pageId).first);
  world.server.rows[strategyId] = rows.withRows([
    elementFrom({
      ...first,
      'publicId': id,
      'sortIndex': 99,
      'revision': 1,
      'createdAt': firstLife + 77,
      'payload': {
        ...(first['payload']! as Map<String, Object?>),
        'payloadVersion': 999,
      },
    }),
  ]);
}

RemotePageSnapshot remotePageOf(World world) {
  final read =
      (world.server.answerNow(ReadCall(strategyId, pageId, servedAccount))
              as StoreReadAnswered)
          .base as PageRead;
  final page = jsonOf(read.page);
  final settings = lived(world.server.rows[strategyId]!.settingsOf(pageId)!);
  return RemotePageSnapshot(
    page: RemotePage(
      publicId: pageId,
      strategyPublicId: strategyId,
      name: page['name']! as String,
      sortIndex: page['sortIndex']! as int,
      isAttack: page['isAttack']! as bool,
      revision: page['revision']! as int,
      createdAt: lifeOf(read.page),
      updatedAt: lifeOf(read.page),
    ),
    content: RemotePageContent(
      settings: jsonOf(settings)['settings'] as Map<String, dynamic>?,
      revision: jsonOf(settings)['revision']! as int,
      createdAt: lifeOf(settings),
      updatedAt: lifeOf(settings),
    ),
    elements: [
      for (final element in read.elements)
        RemoteElement(
          publicId: element.publicId,
          strategyPublicId: strategyId,
          pagePublicId: pageId,
          elementType: (jsonOf(element)['payload']! as Map)['kind']! as String,
          payload: Map<String, dynamic>.from(
            jsonOf(element)['payload']! as Map,
          ),
          sortIndex: jsonOf(element)['sortIndex']! as int,
          revision: jsonOf(element)['revision']! as int,
          deleted: (jsonOf(element)['deleted'] as bool?) ?? false,
          createdAt: lifeOf(element),
        ),
    ],
    lineups: const [],
    assetsById: const {},
  );
}

int deliver(World world) {
  final before = world.sender.liveRowsDecoded;
  world.sender.livePageArrived(
    strategyId,
    openPage,
    servedAccount,
    LivePageAnswer(
      remotePageOf(world),
      pagePublicId: pageId,
      point: world.server.stamp(),
    ),
  );
  world.settle();
  return world.sender.liveRowsDecoded - before;
}

List<PageRead> pageResultsWritten(World world) => [
      for (final event in world.written())
        if (event case BaseArrived(base: final PageRead read)) read,
    ];

Map<String, int> revisionsInStore(World world) {
  Reading<PageContent>? read;
  world.store.readPage(strategyId, pageId).then((value) => read = value);
  world.async.flushMicrotasks();
  return {
    for (final element in (read! as Found<PageContent>).value.elements)
      if (revisionOf(element) case final revision?) element.publicId: revision,
  };
}

Map<String, int> revisionsOnServer(World world) => {
      for (final element in world.server.rows[strategyId]!.elementsOn(pageId))
        if (revisionOf(element) case final revision?)
          element.publicId: revision,
    };
