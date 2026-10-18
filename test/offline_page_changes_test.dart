import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/page_changes.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Page changes made in a cloud strategy without a connection: each one
/// lands, in the order it was made, against a server that applies page
/// changes the way convex/ops.ts does.
void main() {
  late _PageServer server;
  late DurableStrategyOutboxStore store;
  late StateController<bool> online;
  ProviderContainer? container;

  StrategyOpQueueNotifier open() {
    container?.dispose();
    final connection = StateProvider<bool>((ref) => false);
    container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      convexStrategyRepositoryProvider.overrideWithValue(server),
      authProvider.overrideWith(_CloudReadyAuthProvider.new),
      convexConnectionSnapshotProvider
          .overrideWith((ref) => ref.watch(connection)),
      convexConnectionProvider
          .overrideWith((ref) => Stream.value(ref.watch(connection))),
    ]);
    online = container!.read(connection.notifier);
    return container!.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy(_strategyId, accountId: 'account-a');
  }

  StrategyOpQueueState queue() => container!.read(strategyOpQueueProvider);

  /// Brings the connection back and sends until nothing is left to send.
  Future<void> reconnectAndSend(StrategyOpQueueNotifier notifier) async {
    online.state = true;
    for (var i = 0; i < 12 && queue().queuedByEntityKey.isNotEmpty; i++) {
      await notifier.flushNow();
      await _settle();
    }
  }

  /// The page change as the pages bar and page menu make it, against what
  /// they show: the server's pages as last read, which offline do not move.
  PagePatchOp rename(String pageId, String name) => PagePatchOp(
        opId: 'rename-$pageId-$name',
        pagePublicId: pageId,
        payload: {'name': name, 'isAutoNamed': false},
        expectedPageRevision: server.page(pageId).revision,
      );
  PageReorderOp move(String pageId, int to) => PageReorderOp(
        opId: 'move-$pageId-$to',
        pagePublicId: pageId,
        sortIndex: to,
        expectedStrategyRevision: server.revision,
      );
  PageDeleteOp delete(String pageId) => PageDeleteOp(
        opId: 'delete-$pageId',
        pagePublicId: pageId,
        expectedStrategyRevision: server.revision,
      );

  /// A side change of [pageId], as the canvas syncs one.
  Future<void> flipSide(StrategyOpQueueNotifier notifier, String pageId) =>
      notifier.syncDesiredOpsForPage(
        pageId: pageId,
        desiredOpsByEntityKey: {
          EntitySyncKey.pageDescriptor(pageId): PagePatchOp(
            opId: 'side-$pageId',
            pagePublicId: pageId,
            payload: const {'isAttack': false},
            expectedPageRevision: server.page(pageId).revision,
          ),
        },
      );

  setUp(() {
    server = _PageServer(['page-1', 'page-2', 'page-3']);
    store = MemoryDurableStrategyOutboxStore();
  });
  tearDown(() {
    container?.dispose();
    container = null;
  });

  test('a rename then a move of the same page both land', () async {
    final notifier = open();
    await notifier.enqueue(rename('page-2', 'Retake'));
    await notifier.enqueue(move('page-2', 0));

    open();
    await reconnectAndSend(container!.read(strategyOpQueueProvider.notifier));

    expect(server.order, ['page-2', 'page-1', 'page-3']);
    expect(server.page('page-2').name, 'Retake');
    expect(queue().pending, isEmpty);
    expect(queue().needsAttention, isFalse);
  });

  test('a move then a rename of the same page both land', () async {
    final notifier = open();
    await notifier.enqueue(move('page-2', 0));
    await notifier.enqueue(rename('page-2', 'Retake'));

    await reconnectAndSend(notifier);

    expect(server.order, ['page-2', 'page-1', 'page-3']);
    expect(server.page('page-2').name, 'Retake');
    expect(queue().needsAttention, isFalse);
  });

  test('a delete then a side change of the same page: the delete lands',
      () async {
    final notifier = open();
    await notifier.enqueue(delete('page-2'));
    await flipSide(notifier, 'page-2');

    await reconnectAndSend(notifier);

    expect(server.order, ['page-1', 'page-3']);
    expect(server.page('page-2').trashed, isTrue);
    expect(queue().pending, isEmpty);
    expect(queue().needsAttention, isFalse);
  });

  test('a rename and a side change of one page both land', () async {
    final notifier = open();
    await notifier.enqueue(rename('page-2', 'Retake'));
    await flipSide(notifier, 'page-2');

    await reconnectAndSend(notifier);

    expect(server.page('page-2').name, 'Retake');
    expect(server.page('page-2').isAttack, isFalse);
    expect(queue().needsAttention, isFalse);
  });

  test('moves land in the order they were made, after a restart', () async {
    final directory = await Directory.systemTemp.createTemp('icarus-pages-');
    addTearDown(() async {
      await Hive.close();
      await directory.delete(recursive: true);
    });
    Hive.init(directory.path);
    await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
    store = HiveDurableStrategyOutboxStore();
    // Ids whose stored order is not the order the moves are made in.
    server = _PageServer(['z-first', 'a-second', 'm-third']);

    final notifier = open();
    await notifier.enqueue(move('z-first', 2));
    await notifier.enqueue(move('a-second', 2));
    container!.dispose();
    container = null;
    await Hive.close();
    await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);

    await reconnectAndSend(open());

    // [z, a, m] -> z to the end: [a, m, z] -> a to the end: [m, z, a].
    expect(server.order, ['m-third', 'z-first', 'a-second']);
    expect(queue().needsAttention, isFalse);
  });

  test(
      'changes made offline draw over the server pages until a read shows '
      'them', () async {
    final notifier = open();
    await notifier.enqueue(rename('page-2', 'Retake'));
    await notifier.enqueue(move('page-3', 0));
    await notifier.enqueue(delete('page-1'));
    final before = server.snapshot();
    List<String> drawn(RemoteEditorSnapshot snapshot) => [
          for (final page in drawPages(
            snapshot.pages,
            container!
                .read(strategyOpQueueProvider.notifier)
                .pageChangesToDraw(snapshot),
          ))
            '${page.publicId}:${page.name}',
        ];
    const expected = ['page-3:Page 1', 'page-2:Retake'];
    expect(drawn(before), expected);

    // A restart keeps them drawn.
    open();
    expect(drawn(before), expected);

    // Landed, they stay drawn over the read from before they landed.
    await reconnectAndSend(container!.read(strategyOpQueueProvider.notifier));
    expect(queue().pending, isEmpty);
    expect(drawn(before), expected);
    expect(drawn(server.snapshot()), expected);
  });

  test('a delete waits for the edits made on its page before it', () async {
    final notifier = open();
    await notifier.enqueue(const ElementPatchOp(
      opId: 'edit',
      elementPublicId: 'element-1',
      pagePublicId: 'page-2',
      payload: {'value': 'last stroke'},
      expectedElementRevision: 1,
    ));
    await notifier.enqueue(delete('page-2'));

    await reconnectAndSend(notifier);

    final sent = server.calls.expand((ops) => ops).map((op) => op.opId);
    expect(sent, ['edit', 'delete-page-2']);
    expect(server.page('page-2').trashed, isTrue);
  });

  /// The add the "+" button makes: a new page after the others, made
  /// against the strategy revision the pages bar was drawn at.
  PageAddOp add(String pageId, {required int at, required int revision}) =>
      PageAddOp(
        opId: 'add-$pageId',
        pagePublicId: pageId,
        payload: const {'name': 'Page', 'isAutoNamed': true},
        sortIndex: at,
        expectedStrategyRevision: revision,
      );

  test('a delete of a page whose add has not landed waits behind it', () async {
    final notifier = open();
    await notifier.enqueue(add('page-new', at: 3, revision: 1));
    await notifier.enqueue(const PageDeleteOp(
      opId: 'delete-new',
      pagePublicId: 'page-new',
      expectedStrategyRevision: 1,
    ));
    expect(queue().pending.map((pending) => pending.op.opId),
        ['add-page-new', 'delete-new']);

    await reconnectAndSend(notifier);

    expect(server.order, ['page-1', 'page-2', 'page-3']);
    expect(server.page('page-new').trashed, isTrue);
    expect(queue().pending, isEmpty);
    expect(queue().needsAttention, isFalse);
  });

  test(
      'an add whose answer was lost, then a delete of its page: the page '
      'ends deleted on the server', () async {
    final notifier = open();
    online.state = true;
    await _settle();
    await notifier.enqueue(add('page-new', at: 3, revision: 1));
    // The server makes the page, and the connection drops before it says so.
    server.loseNextReply = true;
    await notifier.flushNow();
    await _settle();
    online.state = false;
    expect(server.order, ['page-1', 'page-2', 'page-3', 'page-new']);
    expect(queue().pending.single.op.opId, 'add-page-new');

    // The bar still shows the page as waiting; the user deletes it, against
    // the revision they saw.
    await notifier.enqueue(const PageDeleteOp(
      opId: 'delete-new',
      pagePublicId: 'page-new',
      expectedStrategyRevision: 1,
    ));
    await reconnectAndSend(notifier);

    expect(server.order, ['page-1', 'page-2', 'page-3']);
    expect(server.page('page-new').trashed, isTrue);
    expect(queue().pending, isEmpty);
    expect(queue().needsAttention, isFalse);
  });

  test(
      'a page added, a page moved after it, then the added page deleted: '
      'the pages end as the user saw them', () async {
    final notifier = open();
    // [1, 2, 3] -> add X second: [1, X, 2, 3] -> move 3 after X:
    // [1, X, 3, 2] -> delete X: [1, 3, 2].
    await notifier.enqueue(add('page-x', at: 1, revision: 1));
    await notifier.enqueue(const PageReorderOp(
      opId: 'move-3',
      pagePublicId: 'page-3',
      sortIndex: 2,
      expectedStrategyRevision: 1,
    ));
    await notifier.enqueue(const PageDeleteOp(
      opId: 'delete-x',
      pagePublicId: 'page-x',
      expectedStrategyRevision: 1,
    ));
    final drawn = drawPages(
      server.snapshot().pages,
      notifier.pageChangesToDraw(server.snapshot()),
    ).map((page) => page.publicId);
    expect(drawn, ['page-1', 'page-3', 'page-2']);

    await reconnectAndSend(notifier);

    expect(server.order, drawn);
    expect(queue().pending, isEmpty);
    expect(queue().needsAttention, isFalse);
  });

  group('a rename and a side change made after a page\'s delete', () {
    Future<StrategyOpQueueNotifier> deleteThenEdit() async {
      final notifier = open();
      await notifier.enqueue(delete('page-2'));
      await notifier.enqueue(rename('page-2', 'Retake'));
      await flipSide(notifier, 'page-2');
      return notifier;
    }

    test('go with the page once the delete lands', () async {
      final notifier = await deleteThenEdit();
      expect(queue().pending, hasLength(3));

      await reconnectAndSend(notifier);

      expect(server.page('page-2').trashed, isTrue);
      expect(server.page('page-2').name, 'Page 2');
      expect(
        server.calls.expand((ops) => ops).map((op) => op.opId),
        ['delete-page-2'],
      );
      expect(queue().pending, isEmpty);
      expect(queue().needsAttention, isFalse);
    });

    test('wait while the delete is refused, and land once it is discarded',
        () async {
      final notifier = await deleteThenEdit();
      // A teammate adds a page first: the delete was made against the
      // revision before theirs.
      server.teammateAdds('page-4');

      await reconnectAndSend(notifier);

      expect(server.page('page-2').trashed, isFalse);
      final refused = queue().attentionByEntityKey.entries.single;
      expect(refused.value.pending.op, isA<PageDeleteOp>());
      // Neither is lost or sent while the user decides.
      expect(queue().queuedByEntityKey, hasLength(2));
      expect(server.calls.expand((ops) => ops).map((op) => op.opId),
          ['delete-page-2']);

      await notifier.discardRejected({refused.key});
      await reconnectAndSend(notifier);

      expect(server.order, ['page-1', 'page-2', 'page-3', 'page-4']);
      expect(server.page('page-2').name, 'Retake');
      expect(server.page('page-2').isAttack, isFalse);
      expect(queue().pending, isEmpty);
      expect(queue().needsAttention, isFalse);
    });
  });

  test('a refused move holds the moves made after it, and says so', () async {
    final notifier = open();
    await notifier.enqueue(move('page-1', 2));
    await notifier.enqueue(move('page-2', 0));
    // A teammate reorders first.
    server.teammateMoves('page-3', 0);

    await reconnectAndSend(notifier);

    expect(queue().attentionByEntityKey, hasLength(1));
    expect(queue().queuedByEntityKey, hasLength(1));
    expect(queue().needsAttention, isTrue);
    expect(server.order, ['page-3', 'page-1', 'page-2']);
  });

  group('connected, one person', () {
    test('a rename, a move and a delete each land as they are made', () async {
      final notifier = open();
      online.state = true;
      await _settle();
      for (final op in <StrategyOp Function()>[
        () => rename('page-2', 'Retake'),
        () => move('page-2', 0),
        () => delete('page-3'),
      ]) {
        final made = op();
        await notifier.enqueue(made);
        await notifier.flushNow();
        expect(
          queue().lastAcks.map((ack) => (ack.opId, ack.isAck)),
          [(made.opId, true)],
        );
      }

      expect(server.calls, hasLength(3));
      expect(server.order, ['page-2', 'page-1']);
      expect(server.page('page-2').name, 'Retake');
      expect(queue().pending, isEmpty);
      expect(queue().needsAttention, isFalse);
      expect(queue().lastError, isNull);
    });
  });

  group('page changes saved by a build before the list', () {
    /// A record as builds before the list wrote it: one per page, in the
    /// page's descriptor slot, at outbox version 2.
    DurableOutboxRecord old(
      String pageId,
      StrategyOp op, {
      DurableOutboxStatus status = DurableOutboxStatus.queued,
      PendingOp? successor,
      required int hour,
    }) =>
        DurableOutboxRecord(
          accountId: 'account-a',
          strategyPublicId: _strategyId,
          entityKey: EntitySyncKey.pageDescriptor(pageId),
          pending: PendingOp(op: op, clientId: 'old-client'),
          status: status,
          createdAt: DateTime.utc(2026, 10, 1, hour),
          updatedAt: DateTime.utc(2026, 10, 1, hour),
          successorPending: successor,
        );
    Map<String, dynamic> stored(DurableOutboxRecord record) =>
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(record.toJson()..['outboxVersion'] = 2)) as Map,
        );

    /// A Hive outbox holding [records] as those builds stored them.
    Future<Box<dynamic>> oldOutbox(List<DurableOutboxRecord> records) async {
      final directory = await Directory.systemTemp.createTemp('icarus-old-');
      addTearDown(() async {
        await Hive.close();
        await directory.delete(recursive: true);
      });
      Hive.init(directory.path);
      final box = await Hive.openBox<dynamic>(HiveBoxNames.strategyOutboxBox);
      await box.put(durableOutboxVersionKey, durableOutboxRecordVersion);
      for (final record in records) {
        await box.put(record.storageKey, stored(record));
      }
      store = HiveDurableStrategyOutboxStore();
      return box;
    }

    test(
        'are sent first and unchanged, and the changes made after the '
        'upgrade follow them', () async {
      final moveSecond = move('page-2', 0);
      final renameFirst = rename('page-1', 'Execute');
      final moveFirst = move('page-1', 2);
      const renameAndSide = PagePatchOp(
        opId: 'rename-and-side-3',
        pagePublicId: 'page-3',
        payload: {'name': 'B site', 'isAutoNamed': false, 'isAttack': false},
        expectedPageRevision: 1,
      );
      final records = [
        old('page-2', moveSecond, hour: 9),
        // Being sent when the app closed, with a move made behind it.
        old(
          'page-1',
          renameFirst,
          status: DurableOutboxStatus.inFlight,
          successor: PendingOp(op: moveFirst, clientId: 'old-client'),
          hour: 10,
        ),
        // A rename and a side change, merged into one as those builds did.
        old('page-3', renameAndSide, hour: 11),
      ];
      final box = await oldOutbox(records);
      Map<String, Object?> oldOnDisk() => {
            for (final record in records)
              record.storageKey: box.get(record.storageKey),
          };
      final before = oldOnDisk();

      await prepareDurableStrategyOutbox();
      final notifier = open();
      // The canvas finds the side change where it always was.
      expect(
        queue()
            .queuedByEntityKey[const EntitySyncKey.pageDescriptor('page-3')]
            ?.pending
            .op
            .opId,
        'rename-and-side-3',
      );
      // The pages bar draws them: [1, 2, 3] -> 2 first: [2, 1, 3] -> 1
      // last: [2, 3, 1].
      List<String> drawn() => [
            for (final page in drawPages(
              server.snapshot().pages,
              notifier.pageChangesToDraw(server.snapshot()),
            ))
              page.publicId,
          ];
      expect(drawn(), ['page-2', 'page-3', 'page-1']);
      // Made after the upgrade, offline, against the pages as drawn.
      await notifier.enqueue(PageReorderOp(
        opId: 'move-3-first',
        pagePublicId: 'page-3',
        sortIndex: 0,
        expectedStrategyRevision: notifier.drawnStrategyRevision(
          server.snapshot(),
        ),
      ));
      expect(drawn(), ['page-3', 'page-2', 'page-1']);
      expect(oldOnDisk(), before);

      await reconnectAndSend(container!.read(strategyOpQueueProvider.notifier));

      // Sent in one batch, as those builds sent them, renames first.
      expect(
        server.calls.first.map((op) => jsonEncode(op.toConvexJson())),
        [renameFirst, renameAndSide, moveSecond]
            .map((op) => jsonEncode(op.toConvexJson())),
      );
      expect(
        server.calls.skip(1).map((ops) => ops.map((op) => op.opId).toList()),
        [
          ['move-page-1-2'],
          ['move-3-first'],
        ],
      );
      expect(server.order, ['page-3', 'page-2', 'page-1']);
      expect(server.page('page-1').name, 'Execute');
      expect(server.page('page-3').name, 'B site');
      expect(server.page('page-3').isAttack, isFalse);
      expect(queue().pending, isEmpty);
      expect(queue().needsAttention, isFalse);
      expect(box.keys.where((key) => key != durableOutboxVersionKey), isEmpty);
    });

    test(
        'a rename made after the upgrade goes ahead of a waiting move, which '
        'moves its page', () async {
      await oldOutbox([old('page-2', move('page-2', 0), hour: 9)]);
      final notifier = open();
      // Made against page 1 as drawn: the server's, before the move.
      await notifier.enqueue(rename('page-1', 'Default'));

      await reconnectAndSend(notifier);

      expect(
        server.calls.map((ops) => ops.map((op) => op.opId).toList()),
        [
          ['rename-page-1-Default'],
          ['move-page-2-0'],
        ],
      );
      expect(server.order, ['page-2', 'page-1', 'page-3']);
      expect(server.page('page-1').name, 'Default');
      expect(queue().pending, isEmpty);
      expect(queue().needsAttention, isFalse);
    });

    test(
        'a side change of a page whose slot holds a waiting move waits '
        'behind the move, which is kept', () async {
      await oldOutbox([old('page-2', move('page-2', 0), hour: 9)]);
      final notifier = open();

      await flipSide(notifier, 'page-2');
      expect(
        queue()
            .successorByEntityKey[const EntitySyncKey.pageDescriptor('page-2')]
            ?.pending
            .op
            .opId,
        'side-page-2',
      );

      await reconnectAndSend(notifier);

      expect(server.order, ['page-2', 'page-1', 'page-3']);
      // Made against the page's revision from before the move moved it, the
      // side change is refused once and waits for the user: nothing is lost
      // or written over.
      expect(server.page('page-2').isAttack, isTrue);
      expect(
        queue().attentionByEntityKey.values.single.pending.op.opId,
        'side-page-2',
      );
    });

    test(
        'a record a build cannot read is kept as it was, reported, and the '
        'rest still sends', () async {
      // What a build from before the list does with one of this build's
      // page changes: version 4 is past what it reads (1 to 3), so it takes
      // the path this build takes for a version past its own, which is the
      // same code.
      final unreadable = DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: _strategyId,
        entityKey: const EntitySyncKey.pageChange('change-1'),
        pending: PendingOp(op: move('page-2', 0), clientId: 'client'),
        status: DurableOutboxStatus.queued,
        createdAt: DateTime.utc(2026, 10, 18),
        updatedAt: DateTime.utc(2026, 10, 18),
        pageChangeSequence: 1,
      );
      final json = unreadable.toJson();
      expect(json['outboxVersion'], pageChangeOutboxRecordVersion);
      expect(json['entityKey'], 'pagechange:change-1');
      expect(json['pageChangeSequence'], 1);
      expect(DurableOutboxRecord.fromJson(json).pageChangeSequence, 1);

      final box =
          await oldOutbox([old('page-1', rename('page-1', 'A'), hour: 9)]);
      final kept = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(json)) as Map,
      )..['outboxVersion'] = pageChangeOutboxRecordVersion + 1;
      await box.put(unreadable.storageKey, kept);

      await prepareDurableStrategyOutbox();
      final notifier = open();
      expect(queue().loadIssues.single.storageKey, unreadable.storageKey);
      // Sign-out and new media references wait while it is unreadable.
      expect(queue().outboxIsReliable, isFalse);

      await reconnectAndSend(notifier);

      expect(server.page('page-1').name, 'A');
      expect(server.order, ['page-1', 'page-2', 'page-3']);
      expect(box.get(unreadable.storageKey), kept);
    });
  });
}

const _strategyId = 'strategy-1';

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _ServerPage {
  _ServerPage(this.id, this.name, this.sortIndex);

  final String id;
  String name;
  bool isAutoNamed = true;
  bool isAttack = true;
  int sortIndex;
  int revision = 1;
  bool trashed = false;
}

/// A strategy's pages on a server that applies page ops as convex/ops.ts
/// applyPageOp and applyBatch do: adds, deletes and reorders checked
/// against the strategy's revision (same-base ones in a batch chained),
/// renames and side changes against the page's, every page whose place or
/// automatic name changes moving its revision on. Other ops land.
class _PageServer extends ConvexStrategyRepository {
  _PageServer(List<String> ids) : super(IcarusConvexApi(_UnusedTransport())) {
    for (var i = 0; i < ids.length; i++) {
      pages.add(_ServerPage(ids[i], 'Page ${i + 1}', i));
    }
  }

  int revision = 1;
  final List<_ServerPage> pages = [];
  final List<List<StrategyOp>> calls = [];
  final _at = DateTime.utc(2026, 10, 18);

  _ServerPage page(String id) => pages.firstWhere((page) => page.id == id);

  List<_ServerPage> get _live => pages.where((page) => !page.trashed).toList()
    ..sort((left, right) => left.sortIndex.compareTo(right.sortIndex));

  List<String> get order => [for (final page in _live) page.id];

  RemoteEditorSnapshot snapshot() => RemoteEditorSnapshot(
        shell: RemoteStrategyShell(
          header: RemoteStrategyHeader(
            publicId: _strategyId,
            name: 'Strategy',
            mapData: 'ascent',
            revision: revision,
            createdAt: _at,
            updatedAt: _at,
          ),
          pages: [
            for (final page in _live)
              RemotePage(
                publicId: page.id,
                strategyPublicId: _strategyId,
                name: page.name,
                isAutoNamed: page.isAutoNamed,
                sortIndex: page.sortIndex,
                isAttack: page.isAttack,
                revision: page.revision,
                createdAt: _at,
                updatedAt: _at,
              ),
          ],
        ),
        activePage: null,
      );

  void _writeOrder(List<_ServerPage> ordered) {
    for (var i = 0; i < ordered.length; i++) {
      final page = ordered[i];
      final name = page.isAutoNamed ? 'Page ${i + 1}' : page.name;
      if (page.sortIndex != i || page.name != name) {
        page
          ..sortIndex = i
          ..name = name
          ..revision += 1;
      }
    }
  }

  void teammateAdds(String id) {
    pages.add(_ServerPage(id, 'Page ${_live.length + 1}', _live.length));
    revision += 1;
  }

  void teammateMoves(String id, int to) {
    final ordered = _live..removeWhere((page) => page.id == id);
    ordered.insert(to, page(id));
    _writeOrder(ordered);
    revision += 1;
  }

  /// What each op id was answered, so one sent again is answered as the
  /// server does (applyBatch in convex/ops.ts): an op that landed replays
  /// as no change, at the revision it landed at.
  final Map<String, OpAck> _answered = {};

  /// While set, the next batch is applied but its answer never arrives.
  bool loseNextReply = false;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    calls.add(List.of(ops));
    int? acceptedBase;
    final acks = [
      for (final op in ops)
        () {
          final seen = _answered[op.opId];
          if (seen != null) {
            return seen is AppliedOpAck
                ? NoopOpAck(opId: op.opId, currentRevision: seen.revision)
                : seen;
          }
          final before = revision;
          final expected = renumbersPages(op) &&
                  acceptedBase != null &&
                  op.expectedRevision == acceptedBase
              ? revision
              : op.expectedRevision;
          final ack = _apply(op, expected);
          if (renumbersPages(op) &&
              acceptedBase == null &&
              op.expectedRevision == before &&
              ack is AppliedOpAck) {
            acceptedBase = op.expectedRevision;
          }
          return _answered[op.opId] = ack;
        }(),
    ];
    if (loseNextReply) {
      loseNextReply = false;
      throw StateError('The connection dropped before the answer came.');
    }
    return acks;
  }

  OpAck _apply(StrategyOp op, int? expected) {
    RejectedOpAck mismatch() => RejectedOpAck(
          opId: op.opId,
          rejectionReason: OpRejectionReason.revisionMismatch,
        );
    switch (op) {
      case PageReorderOp(:final pagePublicId, :final sortIndex):
        final moved = page(pagePublicId);
        if (moved.trashed) return _pageDeleted(op);
        final ordered = _live;
        final current = ordered.indexOf(moved);
        final to = sortIndex.clamp(0, ordered.length - 1);
        ordered
          ..remove(moved)
          ..insert(to, moved);
        final normalized = [
          for (var i = 0; i < ordered.length; i++) ordered[i].sortIndex == i,
        ].every((ok) => ok);
        if (current == to && normalized) {
          return NoopOpAck(opId: op.opId, currentRevision: revision);
        }
        if (expected != revision) return mismatch();
        _writeOrder(ordered);
        revision += 1;
        return AppliedOpAck(opId: op.opId, revision: revision);
      case PageDeleteOp(:final pagePublicId):
        final deleted = pages.where((page) => page.id == pagePublicId);
        if (deleted.isEmpty || deleted.single.trashed) {
          return NoopOpAck(opId: op.opId, currentRevision: revision);
        }
        if (expected != revision) return mismatch();
        deleted.single.trashed = true;
        _writeOrder(_live);
        revision += 1;
        return AppliedOpAck(opId: op.opId, revision: revision);
      case PageAddOp(:final pagePublicId, :final payload, :final sortIndex):
        if (expected != revision) return mismatch();
        final ordered = _live;
        final added = _ServerPage(
          pagePublicId,
          payload['name'] as String? ?? 'Page',
          sortIndex,
        )..isAutoNamed = payload['isAutoNamed'] == true;
        pages.add(added);
        ordered.insert(sortIndex.clamp(0, ordered.length), added);
        _writeOrder(ordered);
        added.revision = 1;
        revision += 1;
        return AppliedOpAck(opId: op.opId, revision: revision);
      case PagePatchOp(:final pagePublicId, :final payload):
        final patched = pages.where((page) => page.id == pagePublicId);
        if (patched.isEmpty) {
          return RejectedOpAck(
            opId: op.opId,
            rejectionReason: OpRejectionReason.notFound,
          );
        }
        final row = patched.single;
        if (row.trashed) return _pageDeleted(op);
        final name = payload['name'] as String?;
        final isAutoNamed = payload['isAutoNamed'] as bool?;
        final isAttack = payload['isAttack'] as bool?;
        final changes = (name != null && name != row.name) ||
            (isAutoNamed != null && isAutoNamed != row.isAutoNamed) ||
            (isAttack != null && isAttack != row.isAttack);
        if (!changes) {
          return NoopOpAck(opId: op.opId, currentRevision: row.revision);
        }
        if (expected != row.revision) return mismatch();
        row
          ..name = name ?? row.name
          ..isAutoNamed = isAutoNamed ?? row.isAutoNamed
          ..isAttack = isAttack ?? row.isAttack
          ..revision += 1;
        return AppliedOpAck(opId: op.opId, revision: row.revision);
      default:
        return AppliedOpAck(opId: op.opId, revision: 2);
    }
  }

  FailedOpAck _pageDeleted(StrategyOp op) => FailedOpAck(
        opId: op.opId,
        code: 'PAGE_DELETED',
        rawCode: 'PAGE_DELETED',
        message: pageDeletedMessage,
      );
}

class _CloudReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: <String, dynamic>{},
          userMetadata: <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _UnusedTransport implements ConvexTransport {
  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      throw UnimplementedError();
}
