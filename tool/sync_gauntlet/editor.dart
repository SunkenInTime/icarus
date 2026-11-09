// What the canvas and live sync do for the gauntlet: hold what the user has
// drawn, make each edit an op against the version of the item the editor
// last knew the server held, and queue it. It builds ops as
// active_page_live_sync_provider.dart's _strategyOpFromOverlay does: an add
// for an item the server does not hold, a delete, or a patch merged by
// field (field_merge.dart) against the known version. It learns versions as
// live sync does without a live read: from the server when the strategy is
// opened, and from the queue's answers to its own work (lastAckBatch).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:uuid/uuid.dart';

import 'app.dart';

/// An item as the user has it: [payload] null once deleted.
final class Drawn {
  Drawn({required this.payload, required this.sortIndex});

  Map<String, dynamic>? payload;
  int sortIndex;

  Map<String, Object?> toJson() => {'payload': payload, 'sortIndex': sortIndex};

  static Drawn fromJson(Map<String, Object?> json) => Drawn(
        payload: (json['payload'] as Map?)?.cast<String, dynamic>(),
        sortIndex: json['sortIndex'] as int,
      );
}

/// A row as the editor last knew the server held it.
final class Known {
  Known({
    required this.revision,
    required this.payload,
    required this.sortIndex,
    required this.deleted,
  });

  final int revision;
  final Map<String, dynamic>? payload;
  final int? sortIndex;
  final bool deleted;
}

final class Editor {
  Editor(this.app, {required this.strategyId, required this.pageId});

  final GauntletApp app;
  final String strategyId;

  /// The page every element and lineup is on.
  final String pageId;

  /// What the user has drawn, by item id. Lineup ids start with `lineup-`.
  final Map<String, Drawn> drawn = {};

  /// Page names and settings and the strategy name, as the user set them.
  final Map<String, String> pageNames = {};
  final Map<String, int> pageOrder = {};
  final Set<String> pagesDeleted = {};
  Map<String, Object?>? pageSettings;
  String? strategyName;

  final Map<String, Known> _known = {};
  final Map<String, int> _pageRevisions = {};
  int _contentRevision = 0;
  int _strategyRevision = 0;
  ProviderSubscription<StrategyOpQueueState>? _acks;

  static bool isLineup(String id) => id.contains('lineup-');

  /// Reads the strategy as opening it does, and starts following the
  /// queue's answers.
  void hydrate(Map<String, Object?> snapshot) {
    final header = (snapshot['header'] as Map).cast<String, Object?>();
    _strategyRevision = (header['revision'] as num).toInt();
    for (final page in (snapshot['pages'] as List).cast<Map>()) {
      final id = page['publicId'] as String;
      _pageRevisions[id] = (page['revision'] as num).toInt();
      if (id == pageId)
        _contentRevision = (page['contentRevision'] as num).toInt();
    }
    for (final row in [
      ...(snapshot['elements'] as List).cast<Map>(),
      ...(snapshot['lineups'] as List).cast<Map>(),
    ]) {
      _known[row['publicId'] as String] = Known(
        revision: (row['revision'] as num).toInt(),
        payload: (row['payload'] as Map?)?.cast<String, dynamic>(),
        sortIndex: (row['sortIndex'] as num?)?.toInt(),
        deleted: row['deleted'] as bool,
      );
    }
    _acks?.close();
    _acks = app.container.listen<StrategyOpQueueState>(
      strategyOpQueueProvider,
      (previous, next) {
        if (identical(previous?.lastAckBatch, next.lastAckBatch)) return;
        for (final acked in next.lastAckBatch) {
          _learn(acked.op, acked.ack);
        }
      },
    );
  }

  /// The canvas draws the server's version of [row], as it does once the
  /// user takes a teammate's change (Keep theirs).
  void adopt(Map<dynamic, dynamic> row) {
    final id = row['publicId'] as String;
    final payload = (row['payload'] as Map?)?.cast<String, dynamic>();
    final deleted = row['deleted'] as bool;
    _known[id] = Known(
      revision: (row['revision'] as num).toInt(),
      payload: payload,
      sortIndex: (row['sortIndex'] as num?)?.toInt(),
      deleted: deleted,
    );
    drawn[id] = Drawn(
      payload: deleted ? null : payload,
      sortIndex: (row['sortIndex'] as num?)?.toInt() ?? 0,
    );
  }

  void _learn(StrategyOp op, OpAck ack) {
    final revision = ack.appliedRevision;
    if (!ack.isAck || revision == null) return;
    switch (op) {
      case StrategyPatchOp() ||
            PageAddOp() ||
            PageDeleteOp() ||
            PageReorderOp():
        if (revision > _strategyRevision) _strategyRevision = revision;
        if (op case PageAddOp(:final pagePublicId)) {
          _pageRevisions[pagePublicId] ??= 1;
        }
      case PagePatchOp(:final pagePublicId):
        final known = _pageRevisions[pagePublicId] ?? 0;
        if (revision > known) _pageRevisions[pagePublicId] = revision;
      case PageContentPatchOp():
        if (revision > _contentRevision) _contentRevision = revision;
      default:
        final id = op.entityPublicId;
        if (id == null) return;
        final known = _known[id];
        if (known != null && known.revision > revision) return;
        final deleted = op is ElementDeleteOp || op is LineupDeleteOp;
        _known[id] = Known(
          revision: revision,
          payload: deleted
              ? known?.payload
              : (op.payload as Map?)?.cast<String, dynamic>() ?? known?.payload,
          sortIndex: op.sortIndex ?? known?.sortIndex,
          deleted: deleted,
        );
    }
  }

  /// The user draws [id] as [payload] at [sortIndex], or deletes it
  /// (payload null), and the edit is queued.
  Future<void> draw(
    String id, {
    required Map<String, dynamic>? payload,
    required int sortIndex,
  }) async {
    drawn[id] = Drawn(payload: payload, sortIndex: sortIndex);
    final op = _opFor(id, payload, sortIndex);
    if (op == null) return;
    await app.queue.enqueue(op);
  }

  StrategyOp? _opFor(String id, Map<String, dynamic>? payload, int sortIndex) {
    final lineup = isLineup(id);
    final known = _known[id];
    final opId = const Uuid().v4();
    if (payload == null) {
      final revision = known?.revision ?? 0;
      return lineup
          ? LineupDeleteOp(
              opId: opId,
              lineupPublicId: id,
              pagePublicId: pageId,
              expectedLineupRevision: revision,
            )
          : ElementDeleteOp(
              opId: opId,
              elementPublicId: id,
              pagePublicId: pageId,
              expectedElementRevision: revision,
            );
    }
    if (known == null || known.deleted) {
      return lineup
          ? LineupAddOp(
              opId: opId,
              lineupPublicId: id,
              pagePublicId: pageId,
              payload: payload,
              sortIndex: sortIndex,
              expectedLineupRevision: known?.revision,
            )
          : ElementAddOp(
              opId: opId,
              elementPublicId: id,
              pagePublicId: pageId,
              payload: payload,
              sortIndex: sortIndex,
              expectedElementRevision: known?.revision,
            );
    }
    final fields = lineup
        ? lineupMergeFields(known.payload, payload)
        : elementMergeFields(known.payload, payload);
    final moved = sortIndex != known.sortIndex;
    final merge = fields == null
        ? null
        : FieldMerge(
            fields: [...fields, if (moved) placeMergeField],
            base: {
              ...mergeBaseValues(known.payload, fields, lineup: lineup),
              if (moved && known.sortIndex != null)
                placeMergeField: known.sortIndex,
            },
          );
    // Back to the version the editor knows, nothing to write, unless work
    // for the item is still waiting: it will write something else, so this
    // goes behind it (live sync's _needsSuccessor).
    if (merge != null && merge.fields.isEmpty && !_waits(id)) return null;
    return lineup
        ? LineupPatchOp(
            opId: opId,
            lineupPublicId: id,
            pagePublicId: pageId,
            payload: payload,
            sortIndex: sortIndex,
            expectedLineupRevision: known.revision,
            merge: merge,
          )
        : ElementPatchOp(
            opId: opId,
            elementPublicId: id,
            pagePublicId: pageId,
            payload: payload,
            sortIndex: sortIndex,
            expectedElementRevision: known.revision,
            merge: merge,
          );
  }

  bool _waits(String id) {
    bool forItem(QueuedEntityIntent intent) =>
        intent.pending.op.entityPublicId == id;
    final queue = app.queueState;
    return queue.queuedByEntityKey.values.any(forItem) ||
        queue.successorByEntityKey.values.any(forItem) ||
        queue.inFlightByEntityKey.values
            .any((intent) => intent.pending.op.entityPublicId == id);
  }

  Future<void> setPageSettings(Map<String, Object?> settings) async {
    pageSettings = settings;
    await app.queue.enqueue(PageContentPatchOp(
      opId: const Uuid().v4(),
      pagePublicId: pageId,
      settings: Map<String, dynamic>.from(settings),
      expectedPageContentRevision: _contentRevision,
    ));
  }

  Future<void> renameStrategy(String name) async {
    strategyName = name;
    await app.queue.enqueue(StrategyPatchOp(
      opId: const Uuid().v4(),
      payload: {'name': name},
      expectedStrategyRevision: _strategyRevision,
    ));
  }

  Future<void> addPage(String id, String name, int sortIndex) async {
    pageNames[id] = name;
    pageOrder[id] = sortIndex;
    await app.queue.enqueuePageChange(PageAddOp(
      opId: const Uuid().v4(),
      pagePublicId: id,
      payload: {'name': name, 'isAttack': false},
      sortIndex: sortIndex,
      expectedStrategyRevision: _strategyRevision,
    ));
  }

  Future<void> renamePage(String id, String name) async {
    pageNames[id] = name;
    await app.queue.enqueuePageChange(PagePatchOp(
      opId: const Uuid().v4(),
      pagePublicId: id,
      payload: {'name': name},
      expectedPageRevision: _pageRevisions[id] ?? 1,
    ));
  }

  Future<void> movePage(String id, int sortIndex) async {
    pageOrder[id] = sortIndex;
    await app.queue.enqueuePageChange(PageReorderOp(
      opId: const Uuid().v4(),
      pagePublicId: id,
      sortIndex: sortIndex,
      expectedStrategyRevision: _strategyRevision,
    ));
  }

  Future<void> deletePage(String id) async {
    pagesDeleted.add(id);
    pageNames.remove(id);
    pageOrder.remove(id);
    await app.queue.enqueuePageChange(PageDeleteOp(
      opId: const Uuid().v4(),
      pagePublicId: id,
      expectedStrategyRevision: _strategyRevision,
    ));
  }

  /// The user's work, for the process that comes after a restart.
  Map<String, Object?> toJson() => {
        'drawn': {
          for (final entry in drawn.entries) entry.key: entry.value.toJson(),
        },
        'pageNames': pageNames,
        'pageOrder': pageOrder,
        'pagesDeleted': pagesDeleted.toList(),
        'pageSettings': pageSettings,
        'strategyName': strategyName,
      };

  void restore(Map<String, Object?> json) {
    for (final entry in (json['drawn'] as Map).entries) {
      drawn[entry.key as String] = Drawn.fromJson(
        (entry.value as Map).cast<String, Object?>(),
      );
    }
    pageNames.addAll((json['pageNames'] as Map).cast<String, String>());
    pageOrder.addAll((json['pageOrder'] as Map).cast<String, int>());
    pagesDeleted.addAll((json['pagesDeleted'] as List).cast<String>());
    pageSettings = (json['pageSettings'] as Map?)?.cast<String, Object?>();
    strategyName = json['strategyName'] as String?;
  }

  void close() => _acks?.close();
}
