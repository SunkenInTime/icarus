import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/const/image_scale_policy.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/editor_operation_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/collab/cloud_payload_upgrade.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/migrations/paranoia_range_migration.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/weapons.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/transition_provider.dart'
    hide PageTransitionState;
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

class _FakeRemoteEditorNotifier extends RemoteEditorSnapshotNotifier {
  _FakeRemoteEditorNotifier(
    this.initialSnapshot, {
    Map<String, RemotePageSnapshot>? pageCatalog,
  }) : pageCatalog = Map<String, RemotePageSnapshot>.from(
          pageCatalog ??
              <String, RemotePageSnapshot>{
                if (initialSnapshot.activePage != null)
                  initialSnapshot.activePage!.page.publicId:
                      initialSnapshot.activePage!,
              },
        );

  RemoteEditorSnapshot initialSnapshot;
  final Map<String, RemotePageSnapshot> pageCatalog;
  int refreshCount = 0;
  final List<String?> selectedPageIds = <String?>[];
  String? failingPageId;

  @override
  Future<RemoteEditorSnapshot?> build() async => initialSnapshot;

  void setSnapshot(RemoteEditorSnapshot snapshot) {
    initialSnapshot = snapshot;
    final active = snapshot.activePage;
    if (active != null) pageCatalog[active.page.publicId] = active;
    state = AsyncData(snapshot);
  }

  @override
  Future<RemotePageSnapshot?> setActivePage(String? pagePublicId) async {
    selectedPageIds.add(pagePublicId);
    if (pagePublicId == failingPageId) {
      throw StateError('Failed to load $pagePublicId');
    }
    final current = state.valueOrNull ?? initialSnapshot;
    final page = pagePublicId == null ? null : pageCatalog[pagePublicId];
    state = AsyncData(RemoteEditorSnapshot(
      shell: current.shell,
      activePage: page,
    ));
    return page;
  }

  @override
  Future<void> refresh() async {
    refreshCount += 1;
    state = AsyncData(initialSnapshot);
  }

  @override
  Future<void> showRestoredPage(String pagePublicId) async {
    selectedPageIds.add(pagePublicId);
    await refresh();
  }

  /// A live read refused for auth: no snapshot until a later read works.
  void failRead() => state = const AsyncData(null);
}

class _FakeStrategyOpQueueNotifier extends StrategyOpQueueNotifier {
  _FakeStrategyOpQueueNotifier({this.blockFlush = false});

  final bool blockFlush;
  bool failDiscard = false;

  /// While set, page writes wait on it before publishing, like the real
  /// queue's durable write.
  Completer<void>? writeGate;
  int flushNowCount = 0;

  /// Plays the server for one flush, like acking what it accepts.
  FutureOr<void> Function()? onFlush;

  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'test-client',
        durableLoaded: true,
      );

  @override
  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {}

  @override
  Future<void> syncDesiredGenericOp({
    required EntitySyncKey entityKey,
    required StrategyOp? desiredOp,
    bool flushImmediately = false,
  }) async {
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    if (desiredOp != null &&
        state.attentionByEntityKey.containsKey(entityKey)) {
      successors[entityKey] = QueuedEntityIntent(
        entityKey: entityKey,
        pending: PendingOp(op: desiredOp, clientId: 'test-client'),
      );
      state = state.copyWith(successorByEntityKey: successors);
      return;
    }
    if (desiredOp == null) {
      // Like the real queue: nothing changed, nothing published.
      if (!queued.containsKey(entityKey)) return;
      queued.remove(entityKey);
    } else {
      queued[entityKey] = QueuedEntityIntent(
        entityKey: entityKey,
        pending: PendingOp(op: desiredOp, clientId: 'test-client'),
      );
    }
    state = state.copyWith(queuedByEntityKey: queued);
  }

  @override
  Future<void> syncDesiredOpsForPage({
    required String pageId,
    required Map<EntitySyncKey, StrategyOp> desiredOpsByEntityKey,
    bool clearMissing = true,
    bool flushImmediately = false,
  }) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    if (clearMissing) {
      queued.removeWhere((key, _) =>
          key.pageId == pageId && !desiredOpsByEntityKey.containsKey(key));
    }
    for (final entry in desiredOpsByEntityKey.entries) {
      if (state.attentionByEntityKey.containsKey(entry.key)) {
        successors[entry.key] = QueuedEntityIntent(
          entityKey: entry.key,
          pending: PendingOp(op: entry.value, clientId: 'test-client'),
        );
        continue;
      }
      queued[entry.key] = QueuedEntityIntent(
        entityKey: entry.key,
        pending: PendingOp(op: entry.value, clientId: 'test-client'),
      );
    }
    state = state.copyWith(
      queuedByEntityKey: queued,
      successorByEntityKey: successors,
    );
  }

  @override
  Future<void> flushNow() async {
    flushNowCount += 1;
    if (blockFlush) await Completer<void>().future;
    await onFlush?.call();
  }

  /// Lands every queued op, as the server accepting them all, each with
  /// [ack] if given.
  void ackQueued({OpAck Function(String opId)? ack}) {
    final landed = state.queuedByEntityKey.values.toList();
    final acks = [
      for (final intent in landed)
        AckedEntityIntent(
          entityKey: intent.entityKey,
          op: intent.pending.op,
          ack: ack?.call(intent.pending.op.opId) ??
              AppliedOpAck(opId: intent.pending.op.opId, revision: 1),
        ),
    ];
    state = state.copyWith(
      queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
      lastAcks: [for (final acked in acks) acked.ack],
      lastAckBatch: acks,
    );
  }

  /// Takes the server's [acks] for the ops [sent], as the real queue does,
  /// in one update: an op the server took leaves the queue, a refused one
  /// waits in attention, and one it never answered (its send failed) stays
  /// queued.
  void answer(Map<EntitySyncKey, StrategyOp> sent, List<OpAck> acks) {
    final ackByOpId = {for (final ack in acks) ack.opId: ack};
    final queued = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.queuedByEntityKey,
    );
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    final answered = <AckedEntityIntent>[];
    for (final MapEntry(:key, value: op) in sent.entries) {
      final ack = ackByOpId[op.opId];
      if (ack == null) continue;
      if (queued[key]?.pending.op.opId == op.opId) queued.remove(key);
      if (!ack.isAck) {
        attention[key] = QueuedEntityIntent(
          entityKey: key,
          pending: PendingOp(op: op, clientId: 'test-client'),
        );
      }
      answered.add(AckedEntityIntent(entityKey: key, op: op, ack: ack));
    }
    state = state.copyWith(
      queuedByEntityKey: queued,
      attentionByEntityKey: attention,
      lastError: attention.isEmpty ? null : 'Some saved work needs attention.',
      clearError: attention.isEmpty,
      lastAcks: [for (final acked in answered) acked.ack],
      lastAckBatch: answered,
    );
  }

  @override
  Future<Set<EntitySyncKey>> discardRejected(
    Set<EntitySyncKey> entityKeys,
  ) async {
    if (failDiscard) return {};
    final attention = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.attentionByEntityKey,
    );
    final successors = Map<EntitySyncKey, QueuedEntityIntent>.from(
      state.successorByEntityKey,
    );
    final discarded = attention.keys.toSet().intersection(entityKeys);
    for (final key in discarded) {
      attention.remove(key);
      successors.remove(key);
    }
    state = state.copyWith(
      attentionByEntityKey: attention,
      successorByEntityKey: successors,
      clearError: attention.isEmpty,
    );
    return discarded;
  }

  @override
  Future<bool> discardDeletedPage(String pageId) async {
    Map<EntitySyncKey, QueuedEntityIntent> withoutPage(
            Map<EntitySyncKey, QueuedEntityIntent> intents) =>
        {
          for (final entry in intents.entries)
            if (entry.key.pageId != pageId) entry.key: entry.value,
        };
    state = state.copyWith(
      queuedByEntityKey: withoutPage(state.queuedByEntityKey),
      pausedByEntityKey: withoutPage(state.pausedByEntityKey),
      attentionByEntityKey: withoutPage(state.attentionByEntityKey),
      successorByEntityKey: withoutPage(state.successorByEntityKey),
    );
    return !state.inFlightByEntityKey.keys.any((key) => key.pageId == pageId);
  }

  void reject(StrategyOp op) {
    final key = EntitySyncKey.forStrategyOp(op)!;
    final pending = PendingOp(op: op, clientId: 'test-client');
    final ack = RejectedOpAck(
      opId: op.opId,
      rejectionReason: OpRejectionReason.revisionMismatch,
      current: const ElementCurrentSnapshot(revision: 2, value: {}),
    );
    state = state.copyWith(
      queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
      attentionByEntityKey: {
        key: QueuedEntityIntent(entityKey: key, pending: pending),
      },
      isFlushing: false,
      lastError: 'Some saved work needs attention.',
      lastAcks: [ack],
      lastAckBatch: [
        AckedEntityIntent(entityKey: key, op: op, ack: ack),
      ],
    );
  }

  /// Parks [op] after too many failed sends, as paused work.
  void pause(StrategyOp op) {
    final key = EntitySyncKey.forStrategyOp(op)!;
    state = state.copyWith(
      pausedByEntityKey: {
        ...state.pausedByEntityKey,
        key: QueuedEntityIntent(
          entityKey: key,
          pending: PendingOp(op: op, clientId: 'test-client'),
        ),
      },
      lastError: 'Some saved work is paused.',
    );
  }

  /// Pages [retryRestoredPage] was asked for, with whether any of the
  /// page's work was still in flight then, and whether any was refused.
  final List<({String pageId, bool inFlight, bool refused})>
      restoredPageRetries = [];

  @override
  Future<void> retryRestoredPage(String pageId) async {
    bool onPage(EntitySyncKey key) => key.pageId == pageId;
    restoredPageRetries.add((
      pageId: pageId,
      inFlight: state.inFlightByEntityKey.keys.any(onPage),
      refused: state.attentionByEntityKey.keys.any(onPage),
    ));
  }

  /// Live page sets [retryRestoredPages] was asked to re-send for.
  final List<Set<String>> livePageRetries = [];

  @override
  Future<void> retryRestoredPages(Set<String> livePageIds) async =>
      livePageRetries.add(livePageIds);

  void holdInFlight(EntitySyncKey key, StrategyOp op) {
    state = state.copyWith(
      inFlightByEntityKey: {
        key: InFlightEntityIntent(
          entityKey: key,
          pending: PendingOp(op: op, clientId: 'test-client'),
          sentAt: DateTime.utc(2026),
        ),
      },
    );
  }

  void clearInFlight() {
    state = state.copyWith(
      inFlightByEntityKey: const <EntitySyncKey, InFlightEntityIntent>{},
    );
  }
}

/// Plays the server's page restore: [onRestore] runs for each call, and
/// may throw as the server would.
class _RestoringRepository implements ConvexStrategyRepository {
  _RestoringRepository(this.onRestore);

  FutureOr<void> Function(String pagePublicId) onRestore;
  final List<String> restoredPageIds = [];

  @override
  Future<void> restorePage({
    required String strategyPublicId,
    required String pagePublicId,
  }) async {
    restoredPageIds.add(pagePublicId);
    await onRestore(pagePublicId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Plays the server for the real queue: holds its first batch until
/// [landFirst], and accepts every later one at once.
class _HeldFirstBatchRepository implements ConvexStrategyRepository {
  final List<List<StrategyOp>> calls = [];
  final firstSent = Completer<void>();
  final _firstAnswer = Completer<void>();
  final _sent = StreamController<StrategyOp>.broadcast();

  void landFirst() => _firstAnswer.complete();

  /// The next element op for [elementId] sent after this call.
  Future<StrategyOp> nextEditOf(String elementId) => _sent.stream
      .firstWhere((op) => op.entityPublicId == elementId)
      .timeout(const Duration(seconds: 5));

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    calls.add(ops);
    if (calls.length == 1) {
      firstSent.complete();
      await _firstAnswer.future;
    } else {
      ops.forEach(_sent.add);
    }
    return [
      for (final op in ops)
        AppliedOpAck(opId: op.opId, revision: (op.expectedRevision ?? 0) + 1),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

class _RecordingMediaQueue extends CloudMediaUploadQueueNotifier {
  final List<String> rechecked = [];

  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);

  @override
  Future<void> recheckAfterDiscardedWork(String strategyPublicId) async {
    rechecked.add(strategyPublicId);
  }
}

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// Waits, in real time, until [condition] holds.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('The condition never held.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Plays the server for the real queue: [server] answers every batch, and
/// [afterBatch] runs once it has, before the answers reach the queue (as
/// the live read showing the batch can arrive before its answers).
class _ServerRepository implements ConvexStrategyRepository {
  _ServerRepository(this.server, {required this.afterBatch});

  final _FakeServer server;
  final void Function() afterBatch;
  final List<List<StrategyOp>> batches = [];

  /// While set, a batch waits for it before it reaches the server.
  Completer<void>? hold;

  /// While set, the next batch reaches the server, then this runs and the
  /// answer is lost on its way back: the send fails as if offline.
  void Function()? loseNextAnswer;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    batches.add(ops);
    await hold?.future;
    final acks = server.applyBatch(ops);
    if (loseNextAnswer case final lose?) {
      loseNextAnswer = null;
      lose();
      throw const SocketException('The answer was lost.');
    }
    afterBatch();
    return acks;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

RemotePage _page(String id, int index,
    {int revision = 1, String? name, bool isAttack = true}) {
  final now = DateTime.utc(2026);
  return RemotePage(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    name: name ?? 'Page ${index + 1}',
    sortIndex: index,
    isAttack: isAttack,
    revision: revision,
    createdAt: now,
    updatedAt: now,
  );
}

RemoteElement _textElement(
  String pageId,
  String id,
  String value, {
  int revision = 1,
  int sortIndex = 0,
  bool worldSized = false,
  bool deleted = false,
}) {
  final text = PlacedText(id: id, position: const Offset(10, 20))..text = value;
  if (worldSized) text.markSizeAsWorld();
  final payload = Map<String, dynamic>.from(text.toJson())
    ..['elementType'] = 'text';
  return RemoteElement(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    pagePublicId: pageId,
    elementType: 'text',
    payload: cloudElementPayload(kind: 'text', data: payload),
    sortIndex: sortIndex,
    revision: revision,
    deleted: deleted,
  );
}

RemotePageSnapshot _pageSnapshot(
  RemotePage page, {
  String? text,
  int contentRevision = 1,
  CloudPayload settings = const {},
  List<RemoteElement>? elements,
  List<RemoteLineup> lineups = const [],
}) {
  final now = DateTime.utc(2026);
  return RemotePageSnapshot(
    page: page,
    content: RemotePageContent(
      settings: settings,
      revision: contentRevision,
      createdAt: now,
      updatedAt: now,
    ),
    elements: elements ??
        (text == null
            ? const []
            : [_textElement(page.publicId, 'text-${page.publicId}', text)]),
    lineups: lineups,
    assetsById: const {},
  );
}

Map<String, dynamic> _agentJson(String id, Offset position) => {
      'id': 'agent-$id',
      'isDeleted': false,
      'position': {'dx': position.dx, 'dy': position.dy},
      'type': 'sova',
      'isAlly': true,
      'state': 'none',
      'kind': 'plain',
      'lineUpID': id,
    };

Map<String, dynamic> _abilityJson(
  String id, [
  Offset position = const Offset(30, 40),
]) =>
    {
      'id': 'ability-$id',
      'isDeleted': false,
      'data': {'type': 'sova', 'index': 2.0},
      'position': {'dx': position.dx, 'dy': position.dy},
      'isAlly': true,
      'rotation': 0,
      'length': 0,
      'lineUpID': id,
      'visualState': {
        'showRangeOutline': true,
        'showRangeFill': true,
        'showInnerOutline': true,
        'showInnerFill': true,
      },
      'armLengthsMeters': [10, 10, 10, 10],
    };

/// Origin [id] as a lineup row carries it.
Map<String, dynamic> _originJson(
  String id, [
  Offset position = const Offset(10, 20),
]) =>
    {'id': id, 'agent': _agentJson(id, position)};

/// Landing [id] as a lineup row carries it.
Map<String, dynamic> _landingJson(
  String id, [
  Offset position = const Offset(30, 40),
]) =>
    {'id': id, 'ability': _abilityJson(id, position)};

/// One lineup as the server stores it: one row, the link [id] with its own
/// copies of its [origin] and [landing].
RemoteLineup _lineupRow(
  String pageId,
  String id, {
  required Map<String, dynamic> origin,
  required Map<String, dynamic> landing,
  String name = '',
  String notes = 'remote lineup',
  int revision = 1,
  int sortIndex = 0,
  bool deleted = false,
}) {
  return RemoteLineup(
    publicId: id,
    strategyPublicId: 'cloud-strategy',
    pagePublicId: pageId,
    payload: cloudLineupPayload({
      'id': id,
      'name': name,
      'youtubeLink': '',
      'notes': notes,
      'images': <Object?>[],
      'origin': origin,
      'landing': landing,
    }),
    sortIndex: sortIndex,
    revision: revision,
    deleted: deleted,
  );
}

/// A lineup on spots of its own: the link `link-[id]` from the origin [id]
/// to the landing `landing-[id]`.
RemoteLineup _lineup(
  String pageId,
  String id, {
  Offset agentPosition = const Offset(10, 20),
  String linkName = '',
  int revision = 1,
  int sortIndex = 0,
}) {
  return _lineupRow(
    pageId,
    'link-$id',
    origin: _originJson(id, agentPosition),
    landing: _landingJson('landing-$id'),
    name: linkName,
    revision: revision,
    sortIndex: sortIndex,
  );
}

/// The key of the row [_lineup] builds for [id].
EntitySyncKey _lineupKey(String pageId, String id) =>
    EntitySyncKey.lineup(pageId, 'link-$id');

/// [row] as a teammate left it: its data changed by [edit], one revision on.
RemoteLineup _editedLineup(
  RemoteLineup row,
  void Function(Map<String, dynamic> data) edit, {
  bool deleted = false,
}) {
  final payload = jsonDecode(jsonEncode(row.payload)) as CloudPayload;
  edit(payload['data'] as Map<String, dynamic>);
  return RemoteLineup(
    publicId: row.publicId,
    strategyPublicId: row.strategyPublicId,
    pagePublicId: row.pagePublicId,
    payload: payload,
    sortIndex: row.sortIndex,
    revision: row.revision + 1,
    deleted: deleted,
  );
}

/// Plays the server's element and lineup rows of one page as convex/ops.ts
/// keeps them (applyElementOp, applyLineupOp).
///
/// Every row has its own revision, which each change it takes moves on by
/// one. A delete leaves a tombstone: still listed, deleted, one revision on.
/// A write expecting another revision than the row's is refused with the
/// row as it is. A patch or reorder of a tombstone is refused as `deleted`;
/// an add expecting the tombstone's revision brings the row back. A write
/// that would change nothing is a noop, whatever revision it expected. An op
/// sent again (its answer lost) is answered as a noop at the revision it
/// landed at, or refused again.
class _FakeServer {
  _FakeServer(
    this.pageId, {
    Iterable<RemoteLineup> lineups = const [],
    Iterable<RemoteElement> elements = const [],
  }) {
    for (final row in lineups) {
      _lineups[row.publicId] = _Row.lineup(row);
    }
    for (final row in elements) {
      _elements[row.publicId] = _Row.element(row);
    }
  }

  final String pageId;
  final Map<String, _Row> _lineups = {};
  final Map<String, _Row> _elements = {};

  /// The answer to each element and lineup op taken, by op id.
  final Map<String, OpAck> _answers = {};

  /// Every lineup op this server answered, in order.
  final List<StrategyOp> received = [];

  /// Every lineup row, tombstones included, in stored order.
  List<RemoteLineup> get rows => [
        for (final MapEntry(:key, :value) in _sorted(_lineups))
          RemoteLineup(
            publicId: key,
            strategyPublicId: 'cloud-strategy',
            pagePublicId: pageId,
            payload: value.payload,
            sortIndex: value.sortIndex,
            revision: value.revision,
            deleted: value.deleted,
          ),
      ];

  /// The lineup rows lineups are drawn from.
  List<RemoteLineup> get liveRows => [
        for (final row in rows)
          if (!row.deleted) row,
      ];

  RemoteLineup row(String id) => rows.singleWhere((row) => row.publicId == id);

  /// Every element row, tombstones included, in stored order.
  List<RemoteElement> get elements => [
        for (final MapEntry(:key, :value) in _sorted(_elements))
          RemoteElement(
            publicId: key,
            strategyPublicId: 'cloud-strategy',
            pagePublicId: pageId,
            elementType: value.elementType!,
            payload: value.payload,
            sortIndex: value.sortIndex,
            revision: value.revision,
            deleted: value.deleted,
          ),
      ];

  RemoteElement element(String id) =>
      elements.singleWhere((element) => element.publicId == id);

  /// The server's answer to each of [ops], applied in order. An op on
  /// anything but an element or a lineup is applied as sent.
  List<OpAck> applyBatch(Iterable<StrategyOp> ops) =>
      [for (final op in ops) apply(op)];

  OpAck apply(StrategyOp op) {
    final (rows, change) = switch (op) {
      LineupAddOp(:final payload, :final sortIndex) => (
          _lineups,
          (kind: StrategyOpKind.add, payload: payload, sortIndex: sortIndex),
        ),
      LineupPatchOp(:final payload, :final sortIndex) => (
          _lineups,
          (kind: StrategyOpKind.patch, payload: payload, sortIndex: sortIndex),
        ),
      LineupReorderOp(:final sortIndex) => (
          _lineups,
          (kind: StrategyOpKind.reorder, payload: null, sortIndex: sortIndex),
        ),
      LineupDeleteOp() => (
          _lineups,
          (kind: StrategyOpKind.delete, payload: null, sortIndex: null),
        ),
      ElementAddOp(:final payload, :final sortIndex) => (
          _elements,
          (kind: StrategyOpKind.add, payload: payload, sortIndex: sortIndex),
        ),
      ElementPatchOp(:final payload, :final sortIndex) => (
          _elements,
          (kind: StrategyOpKind.patch, payload: payload, sortIndex: sortIndex),
        ),
      ElementReorderOp(:final sortIndex) => (
          _elements,
          (kind: StrategyOpKind.reorder, payload: null, sortIndex: sortIndex),
        ),
      ElementDeleteOp() => (
          _elements,
          (kind: StrategyOpKind.delete, payload: null, sortIndex: null),
        ),
      _ => (null, null),
    };
    if (rows == null || change == null) {
      return AppliedOpAck(
        opId: op.opId,
        revision: (op.expectedRevision ?? 0) + 1,
      );
    }
    if (identical(rows, _lineups)) received.add(op);
    final id = op.entityPublicId!;
    final existing = rows[id];
    OpAck refused(OpRejectionReason reason) => RejectedOpAck(
          opId: op.opId,
          rejectionReason: reason,
          current: existing == null
              ? null
              : identical(rows, _lineups)
                  ? LineupCurrentSnapshot(
                      revision: existing.revision,
                      value: existing.payload,
                    )
                  : ElementCurrentSnapshot(
                      revision: existing.revision,
                      value: existing.payload,
                    ),
        );
    OpAck? stale() => op.expectedRevision == null
        ? refused(OpRejectionReason.missingExpectedRevision)
        : op.expectedRevision != existing!.revision
            ? refused(OpRejectionReason.revisionMismatch)
            : null;
    OpAck store(CloudPayload payload, int sortIndex, {bool deleted = false}) {
      final revision = (existing?.revision ?? 0) + 1;
      rows[id] = _Row(
        payload: payload,
        sortIndex: sortIndex,
        revision: revision,
        deleted: deleted,
        elementType: identical(rows, _lineups)
            ? null
            : existing?.elementType ?? payload['kind'] as String,
      );
      return AppliedOpAck(opId: op.opId, revision: revision);
    }

    OpAck noop() =>
        NoopOpAck(opId: op.opId, currentRevision: existing?.revision);

    // An op already answered is answered again as it was: an accepted one
    // as a noop at the revision it landed at, not the row's latest.
    switch (_answers[op.opId]) {
      case RejectedOpAck(:final rejectionReason):
        return refused(rejectionReason);
      case final OpAck accepted?:
        return NoopOpAck(
          opId: op.opId,
          currentRevision: accepted.appliedRevision,
        );
      case null:
        break;
    }

    OpAck answer() {
      switch (change.kind) {
        case StrategyOpKind.add:
          final payload = change.payload!;
          final sortIndex = change.sortIndex!;
          if (existing == null) return store(payload, sortIndex);
          if (existing.deleted) return stale() ?? store(payload, sortIndex);
          return _sameJson(existing.payload, payload)
              ? noop()
              : refused(OpRejectionReason.alreadyExists);
        case StrategyOpKind.delete:
          if (existing == null || existing.deleted) return noop();
          return stale() ??
              store(existing.payload, existing.sortIndex, deleted: true);
        case StrategyOpKind.patch || StrategyOpKind.reorder:
          if (existing == null) return refused(OpRejectionReason.notFound);
          if (existing.deleted) return refused(OpRejectionReason.deleted);
          final payload = change.payload ?? existing.payload;
          final sortIndex = change.sortIndex ?? existing.sortIndex;
          if (_sameJson(payload, existing.payload) &&
              sortIndex == existing.sortIndex) {
            return noop();
          }
          return stale() ?? store(payload, sortIndex);
      }
    }

    return _answers[op.opId] = answer();
  }

  /// A teammate's change to lineup row [id] lands: [edit] changes its data,
  /// one revision on.
  void teammateEdit(String id, void Function(Map<String, dynamic> data) edit) {
    final row = _lineups[id]!;
    final payload = jsonDecode(jsonEncode(row.payload)) as CloudPayload;
    edit(payload['data'] as Map<String, dynamic>);
    if (_sameJson(payload, row.payload)) return;
    _lineups[id] = row.next(payload: payload);
  }

  /// A teammate's delete of lineup row [id] lands.
  void teammateDelete(String id) =>
      _lineups[id] = _lineups[id]!.next(deleted: true);

  /// A teammate's delete of element row [id] lands.
  void teammateDeleteElement(String id) =>
      _elements[id] = _elements[id]!.next(deleted: true);

  /// A teammate's new lineup [row] lands.
  void teammateAdd(RemoteLineup row) {
    assert(!_lineups.containsKey(row.publicId));
    _lineups[row.publicId] = _Row(
      payload: row.payload,
      sortIndex: row.sortIndex,
      revision: 1,
      deleted: false,
    );
  }

  static Iterable<MapEntry<String, _Row>> _sorted(Map<String, _Row> rows) =>
      rows.entries.toList()
        ..sort((a, b) => a.value.sortIndex != b.value.sortIndex
            ? a.value.sortIndex.compareTo(b.value.sortIndex)
            : a.key.compareTo(b.key));

  static bool _sameJson(Object? left, Object? right) =>
      canonicalCloudJsonEncode(jsonDecode(jsonEncode(left))) ==
      canonicalCloudJsonEncode(jsonDecode(jsonEncode(right)));
}

/// One row as [_FakeServer] stores it.
class _Row {
  _Row({
    required CloudPayload payload,
    required this.sortIndex,
    required this.revision,
    required this.deleted,
    this.elementType,
  }) : payload = jsonDecode(jsonEncode(payload)) as CloudPayload;

  _Row.lineup(RemoteLineup row)
      : this(
          payload: row.payload,
          sortIndex: row.sortIndex,
          revision: row.revision,
          deleted: row.deleted,
        );

  _Row.element(RemoteElement row)
      : this(
          payload: row.payload,
          sortIndex: row.sortIndex,
          revision: row.revision,
          deleted: row.deleted,
          elementType: row.elementType,
        );

  final CloudPayload payload;
  final int sortIndex;
  final int revision;
  final bool deleted;
  final String? elementType;

  /// This row one revision on, as a teammate's write leaves it.
  _Row next({CloudPayload? payload, bool? deleted}) => _Row(
        payload: payload ?? this.payload,
        sortIndex: sortIndex,
        revision: revision + 1,
        deleted: deleted ?? this.deleted,
        elementType: elementType,
      );
}

/// The origin and landing row [row] carries: their ids, and where their
/// markers stand.
({String origin, Offset originAt, String landing, Offset landingAt}) _endsOf(
  RemoteLineup row,
) {
  final data = cloudPayloadData(row.payload);
  final origin = data['origin'] as Map;
  final landing = data['landing'] as Map;
  Offset at(Object? marker) {
    final position = (marker! as Map)['position'] as Map;
    return Offset(
      (position['dx'] as num).toDouble(),
      (position['dy'] as num).toDouble(),
    );
  }

  return (
    origin: origin['id'] as String,
    originAt: at(origin['agent']),
    landing: landing['id'] as String,
    landingAt: at(landing['ability']),
  );
}

RemoteEditorSnapshot _editorSnapshot({
  required List<RemotePage> pages,
  required RemotePageSnapshot activePage,
  int shellRevision = 1,
  String? mapData,
  String? themeProfileId,
  String role = 'owner',
}) {
  final now = DateTime.utc(2026);
  return RemoteEditorSnapshot(
    shell: RemoteStrategyShell(
      header: RemoteStrategyHeader(
        publicId: 'cloud-strategy',
        name: 'Cloud Strategy',
        mapData: mapData ?? Maps.mapNames[MapValue.ascent]!,
        revision: shellRevision,
        createdAt: now,
        updatedAt: now,
        themeProfileId: themeProfileId,
        role: role,
      ),
      pages: pages,
    ),
    activePage: activePage,
  );
}

Future<ProviderContainer> _cloudContainer({
  required _FakeRemoteEditorNotifier remote,
  required _FakeStrategyOpQueueNotifier queue,
  _RecordingMediaQueue? mediaQueue,
  ConvexStrategyRepository? repository,
}) async {
  final container = ProviderContainer(overrides: [
    remoteEditorSnapshotProvider.overrideWith(() => remote),
    strategyOpQueueProvider.overrideWith(() => queue),
    cloudMediaAccountIdProvider.overrideWithValue('account-a'),
    cloudMediaUploadQueueProvider
        .overrideWith(() => mediaQueue ?? _RecordingMediaQueue()),
    if (repository != null)
      convexStrategyRepositoryProvider.overrideWithValue(repository),
  ]);
  addTearDown(container.dispose);
  container.read(strategyProvider.notifier).setFromState(const StrategyState(
        strategyId: 'cloud-strategy',
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      ));
  container.listen(strategyPageSessionProvider, (_, __) {});
  await container.read(remoteEditorSnapshotProvider.future);
  return container;
}

Future<ProviderContainer> _syncContainer({
  required _FakeRemoteEditorNotifier remote,
  required _FakeStrategyOpQueueNotifier queue,
}) async {
  final container = ProviderContainer(overrides: [
    remoteEditorSnapshotProvider.overrideWith(() => remote),
    strategyOpQueueProvider.overrideWith(() => queue),
  ]);
  addTearDown(container.dispose);
  await container.read(remoteEditorSnapshotProvider.future);
  return container;
}

Future<Box<StrategyData>> _openStrategyBox() async {
  final temp = await Directory.systemTemp.createTemp('icarus-page-session-');
  Hive.init(temp.path);
  if (!Hive.isAdapterRegistered(9)) registerIcarusAdapters(Hive);
  final box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
  addTearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });
  return box;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => CoordinateSystem(playAreaSize: const Size(1920, 1080)));

  test('cloud strategy metadata patch carries the remote shell revision',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
      shellRevision: 17,
      mapData: Maps.mapNames[MapValue.haven],
      themeProfileId: 'remote-theme',
    ));
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );

    await container
        .read(strategyProvider.notifier)
        .notifyCloudStrategyMutation();

    final op = container.read(strategyOpQueueProvider).pending.single.op;
    expect(op.entityType, StrategyOpEntityType.strategy);
    expect(op.expectedRevision, 17);
    expect(op.toConvexJson()['expectedStrategyRevision'], 17);
    expect(
      op.payload,
      containsPair('mapData', Maps.mapNames[MapValue.ascent]),
    );
    expect(op.payload, containsPair('clearThemeProfileId', true));
  });

  test('cloud page reorder is persisted as a page descriptor op', () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second],
        activePage: _pageSnapshot(first),
        shellRevision: 17,
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).reorderPage(0, 2);

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.reorder);
    expect(pending.op.entityPublicId, 'page-1');
    expect(pending.op.sortIndex, 1);
    expect(pending.op.expectedRevision, 17);
    expect(intent.key, const EntitySyncKey.pageDescriptor('page-1'));
    expect(queue.flushNowCount, 1);
  });

  test('cloud page add is persisted with its descriptor and content', () async {
    final page = _page('page-1', 0);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
        shellRevision: 8,
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).addPage('Execute');

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.add);
    expect(pending.op.entityPublicId, isNotEmpty);
    expect(pending.op.sortIndex, 1);
    expect(pending.op.expectedRevision, 8);
    expect(pending.op.payload, {
      'name': 'Execute',
      'isAutoNamed': false,
      'isAttack': true,
      'settings': container.read(strategySettingsProvider).toJson(),
    });
    expect(
      intent.key,
      EntitySyncKey.pageDescriptor(pending.op.entityPublicId!),
    );
    expect(queue.flushNowCount, 1);
  });

  test('cloud page rename is persisted with the page revision', () async {
    final page = _page('page-1', 0, revision: 6);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).renamePage(
          'page-1',
          '  Retake  ',
        );

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.patch);
    expect(pending.op.entityPublicId, 'page-1');
    expect(pending.op.payload, {
      'name': 'Retake',
      'isAutoNamed': false,
    });
    expect(pending.op.expectedRevision, 6);
    expect(intent.key, const EntitySyncKey.pageDescriptor('page-1'));
    expect(queue.flushNowCount, 1);
  });

  test('a cloud page delete reports whether the server took it', () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    Future<ProviderContainer> open(_FakeStrategyOpQueueNotifier queue) =>
        _cloudContainer(
          remote: _FakeRemoteEditorNotifier(_editorSnapshot(
            pages: [first, second],
            activePage: _pageSnapshot(first),
          )),
          queue: queue,
        );

    // No answer from the server: nothing to undo, so no undo is offered.
    final unanswered = await open(_FakeStrategyOpQueueNotifier());
    expect(
      await unanswered.read(strategyProvider.notifier).deletePage('page-2'),
      isFalse,
    );

    final queue = _FakeStrategyOpQueueNotifier();
    queue.onFlush = () async => queue.ackQueued();
    final accepted = await open(queue);
    expect(
      await accepted.read(strategyProvider.notifier).deletePage('page-2'),
      isTrue,
    );

    // A teammate deleted it first: this delete lands as a no-op, so there is
    // nothing of this user's to undo.
    final noopQueue = _FakeStrategyOpQueueNotifier();
    noopQueue.onFlush =
        () async => noopQueue.ackQueued(ack: (opId) => NoopOpAck(opId: opId));
    final alreadyGone = await open(noopQueue);
    expect(
      await alreadyGone.read(strategyProvider.notifier).deletePage('page-2'),
      isFalse,
    );
  });

  QueuedEntityIntent refusedOnPage2() => const QueuedEntityIntent(
        entityKey: EntitySyncKey.element('page-2', 'text-2'),
        pending: PendingOp(
          op: ElementDeleteOp(
            opId: 'refused-op',
            pagePublicId: 'page-2',
            elementPublicId: 'text-2',
            expectedElementRevision: 1,
          ),
          clientId: 'test-client',
        ),
      );

  test('opening a strategy re-sends edits for pages that came back meanwhile',
      () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    // Restored while the strategy was closed: already live on first load.
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [first, second],
      activePage: _pageSnapshot(first),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    queue.state = queue.state.copyWith(attentionByEntityKey: {
      const EntitySyncKey.element('page-2', 'text-2'): refusedOnPage2(),
    });

    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    await _settle();
    expect(queue.livePageRetries.last, contains('page-2'));
  });

  test('"Use cloud" is not overridden when its refresh finds the page back',
      () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [first],
      activePage: _pageSnapshot(first),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );
    queue.state = queue.state.copyWith(attentionByEntityKey: {
      const EntitySyncKey.element('page-2', 'text-2'): refusedOnPage2(),
    });
    // A teammate restored page-2; "Use cloud"'s refresh is what shows it.
    remote.initialSnapshot = _editorSnapshot(
      pages: [first, second],
      activePage: _pageSnapshot(first, contentRevision: 2),
    );

    await session.useCloudVersionsForRejected();
    await _settle();
    expect(queue.livePageRetries, isEmpty);
  });

  test('edits refused for a deleted page go out again once it is live',
      () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [first],
      activePage: _pageSnapshot(first),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    // An edit to page-2 was refused while page-2 was in the trash.
    const refused = ElementDeleteOp(
      opId: 'refused-op',
      pagePublicId: 'page-2',
      elementPublicId: 'text-2',
      expectedElementRevision: 1,
    );
    const key = EntitySyncKey.element('page-2', 'text-2');
    queue.state = queue.state.copyWith(attentionByEntityKey: {
      key: const QueuedEntityIntent(
        entityKey: key,
        pending: PendingOp(op: refused, clientId: 'test-client'),
      ),
    });

    // Still deleted: nothing to re-send.
    remote.setSnapshot(_editorSnapshot(
      pages: [first],
      activePage: _pageSnapshot(first, contentRevision: 2),
    ));
    await _settle();
    expect(queue.livePageRetries, isEmpty);

    // Restored, say by a teammate: its refused edits go out again.
    remote.setSnapshot(_editorSnapshot(
      pages: [first, second],
      activePage: _pageSnapshot(first, contentRevision: 3),
    ));
    await _settle();
    expect(queue.livePageRetries.single, contains('page-2'));
  });

  test('cloud page delete is persisted with the shell revision', () async {
    final first = _page('page-1', 0);
    final second = _page('page-2', 1);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second],
        activePage: _pageSnapshot(first),
        shellRevision: 12,
      )),
      queue: queue,
    );

    await container.read(strategyProvider.notifier).deletePage('page-2');

    final intent = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .single;
    final pending = intent.value.pending;
    expect(pending.op.entityType, StrategyOpEntityType.page);
    expect(pending.op.kind, StrategyOpKind.delete);
    expect(pending.op.entityPublicId, 'page-2');
    expect(pending.op.expectedRevision, 12);
    expect(intent.key, const EntitySyncKey.pageDescriptor('page-2'));
    expect(queue.flushNowCount, 1);
  });

  test('tombstone restore op carries the remote entity revision', () async {
    final page = _page('page-1', 0);
    final element = _textElement(
      page.publicId,
      'restored-text',
      'deleted remotely',
      revision: 4,
      deleted: true,
    );
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, elements: [element]),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: element.publicId, position: const Offset(10, 20))
        ..text = 'restored locally',
    ]);
    container.read(activePageLiveSyncProvider.notifier).markPageHydrated(
          strategyPublicId: 'cloud-strategy',
          pageId: page.publicId,
          snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
        );

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    final op = desired![EntitySyncKey.element(page.publicId, element.publicId)];
    expect(op, isNotNull);
    expect(op!.kind, StrategyOpKind.add);
    expect(op.expectedRevision, 4);
    expect(op.toConvexJson()['expectedElementRevision'], 4);
  });

  test('active page update rehydrates without a strategy revision change',
      () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
      shellRevision: 4,
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    expect(container.read(textProvider).single.text, 'before');

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'after', contentRevision: 2),
      shellRevision: 4,
    ));
    await _settle();
    expect(container.read(textProvider).single.text, 'after');
  });

  test('failed animated page switch restores the previous idle page', () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final pageOneSnapshot = _pageSnapshot(pageOne, text: 'one');
    final pageTwoSnapshot = _pageSnapshot(pageTwo, text: 'two');
    final remote = _FakeRemoteEditorNotifier(
      _editorSnapshot(
        pages: [pageOne, pageTwo],
        activePage: pageOneSnapshot,
      ),
      pageCatalog: {
        pageOne.publicId: pageOneSnapshot,
        pageTwo.publicId: pageTwoSnapshot,
      },
    );
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    remote.failingPageId = pageTwo.publicId;

    await expectLater(
      container
          .read(strategyPageSessionProvider.notifier)
          .setActivePageAnimated(
            pageTwo.publicId,
            direction: PageTransitionDirection.forward,
          ),
      throwsStateError,
    );

    final session = container.read(strategyPageSessionProvider);
    expect(session.activePageId, pageOne.publicId);
    expect(session.transitionState, PageTransitionState.idle);
    expect(container.read(transitionProvider).active, isFalse);
    expect(remote.selectedPageIds, [pageTwo.publicId, pageOne.publicId]);
    expect(
      container.read(activePageLiveSyncProvider).hydratedPageId,
      pageOne.publicId,
    );
  });

  test('remote hydration waits until an unchanged text draft is dismissed',
      () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    const textId = 'text-page-1';
    container.read(textDraftProvider.notifier).setDraft(textId, 'before');
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'after', contentRevision: 2),
    ));
    await _settle();

    expect(container.read(textProvider).single.text, 'before');
    expect(container.read(textDraftProvider)[textId], 'before');

    container.read(textDraftProvider.notifier).clearDraft(textId);
    await _settle();

    expect(container.read(textProvider).single.text, 'after');
  });

  test(
      'a streamed update lands while a stroke is drawn, and the stroke is kept',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    // The pen is down on the canvas, over no item.
    container.read(editorPointersProvider.notifier)
      ..markCanvas(1)
      ..down(1);
    final drawing = container.read(drawingProvider.notifier);
    drawing.startFreeDrawing(
        const Offset(10, 20),
        CoordinateSystem.instance,
        Colors.white,
        2,
        false,
        false,
        false,
        TraversalSpeedProfile.values.first);
    final draft = container.read(drawingProvider).currentElement;
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'after', contentRevision: 2),
    ));
    await _settle();
    expect(container.read(drawingProvider).currentElement, same(draft));
    expect(container.read(textProvider).single.text, 'after');

    drawing.finishFreeDrawing(const Offset(40, 50), CoordinateSystem.instance);
    container.read(editorPointersProvider.notifier).release(1);
    await _settle();
    expect(container.read(drawingProvider).elements.single.id, draft!.id);
    expect(
        container
            .read(strategyOpQueueProvider)
            .pending
            .map((item) => item.op.entityPublicId),
        contains(draft.id));
    expect(container.read(textProvider).single.text, 'after');
  });

  test('a streamed update lands during lineup placement and keeps it',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    ));
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    container.read(lineUpProvider.notifier).startFresh();
    final placement = container.read(lineUpProvider).placement;
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'after', contentRevision: 2),
    ));
    await _settle();
    expect(container.read(lineUpProvider).placement, same(placement));
    expect(container.read(textProvider).single.text, 'after');
    expect(container.read(strategyOpQueueProvider).pending, isEmpty);
  });

  /// Page one on screen with a stroke finished after a teammate deleted it:
  /// work live sync can no longer send anywhere.
  Future<
      ({
        ProviderContainer container,
        _FakeRemoteEditorNotifier remote,
        _FakeStrategyOpQueueNotifier queue,
        RemotePage one,
        RemotePage two,
        String strokeId,
      })> strokeOnDeletedPage({
    /// Clears the unsaved mark before the pointer lifts, as an unrelated op
    /// landing does.
    bool unrelatedAckFirst = false,
    _RecordingMediaQueue? mediaQueue,
    ConvexStrategyRepository? repository,
  }) async {
    final one = _page('page-1', 0, name: 'A exec');
    final two = _page('page-2', 1);
    final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [one, two],
          activePage: _pageSnapshot(one, text: 'one'),
          themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
        ),
        pageCatalog: {
          one.publicId: _pageSnapshot(one, text: 'one'),
          two.publicId: _pageSnapshot(two, text: 'two'),
        });
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: remote,
      queue: queue,
      mediaQueue: mediaQueue,
      repository: repository,
    );
    container.read(strategyPageSessionProvider.notifier).pageWorkSettleTimeout =
        const Duration(milliseconds: 100);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    container.read(editorPointersProvider.notifier)
      ..markCanvas(1)
      ..down(1);
    container.read(drawingProvider.notifier).startFreeDrawing(
        const Offset(10, 20),
        CoordinateSystem.instance,
        Colors.white,
        2,
        false,
        false,
        false,
        TraversalSpeedProfile.values.first);
    final draft = container.read(drawingProvider).currentElement;

    remote.setSnapshot(_editorSnapshot(
      pages: [two],
      activePage: _pageSnapshot(two, text: 'two'),
      themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
    ));
    await _settle();
    // Replacing the page waits for the stroke in progress.
    expect(container.read(drawingProvider).currentElement, same(draft));
    expect(container.read(textProvider).single.text, 'one');

    container
        .read(drawingProvider.notifier)
        .finishFreeDrawing(const Offset(40, 50), CoordinateSystem.instance);
    if (unrelatedAckFirst) {
      await _settle();
      container.read(strategySaveStateProvider.notifier).markPersisted();
    }
    container.read(editorPointersProvider.notifier).release(1);
    await _settle();
    return (
      container: container,
      remote: remote,
      queue: queue,
      one: one,
      two: two,
      strokeId: draft!.id,
    );
  }

  test(
      'a teammate deleting the page on screen says the unsaved stroke '
      'cannot be saved', () async {
    final (:container, :one, :strokeId, queue: _, remote: _, two: _) =
        await strokeOnDeletedPage();

    // The stroke can never be sent to a page the server no longer has.
    // Before, the page stayed on screen with the sync button spinning for
    // good; now the user is told, and nothing moves until they have read it.
    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, (pageId: one.publicId, name: 'A exec'));
    expect(session.activePageId, one.publicId);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
    expect(
        container
            .read(strategyOpQueueProvider)
            .pending
            .where((pending) => pending.op.pagePublicId == one.publicId),
        isEmpty);

    // Leaving before then would drop the stroke unseen.
    await container
        .read(strategyPageSessionProvider.notifier)
        .setActivePage('page-2');
    expect(
        container.read(strategyPageSessionProvider).activePageId, one.publicId);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
  });

  test('switching pages before the notice shows still tells the user first',
      () async {
    final (:container, :remote, :one, :strokeId, queue: _, two: _) =
        await strokeOnDeletedPage();
    // Take back the notice: as if the finished stroke landed while the
    // replacement page was still loading, before anything asked.
    container.read(strategyPageSessionProvider.notifier).setStateForTest(
        container
            .read(strategyPageSessionProvider)
            .copyWith(clearDeletedPage: true));
    // The tap on the page selector is still down when it switches.
    container.read(editorPointersProvider.notifier).down(2);

    await container
        .read(strategyPageSessionProvider.notifier)
        .setActivePageAnimated(
          'page-2',
          direction: PageTransitionDirection.forward,
        );

    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage?.pageId, one.publicId);
    expect(session.activePageId, one.publicId);
    expect(session.transitionState, PageTransitionState.idle);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
    expect(remote.selectedPageIds, isNot(contains('page-2')));
  });

  test('an unrelated op landing does not let the page go unseen', () async {
    final (:container, :one, :strokeId, queue: _, remote: _, two: _) =
        await strokeOnDeletedPage(unrelatedAckFirst: true);

    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage?.pageId, one.publicId);
    expect(session.activePageId, one.publicId);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
  });

  test("the user's own deletion of the page on screen says nothing", () async {
    final one = _page('page-1', 0);
    final two = _page('page-2', 1);
    final loadedOne = _pageSnapshot(
      one,
      settings: StrategySettings().toJson(),
      elements: const [],
    );
    final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [one, two],
          activePage: loadedOne,
          themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
        ),
        pageCatalog: {
          one.publicId: loadedOne,
          two.publicId: _pageSnapshot(two, text: 'two'),
        });
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    // The delete has landed and the live read shows it before its ack.
    queue.holdInFlight(
      EntitySyncKey.pageDescriptor(one.publicId),
      PageDeleteOp(
        opId: 'delete-page',
        pagePublicId: one.publicId,
        expectedStrategyRevision: 1,
      ),
    );
    remote.setSnapshot(_editorSnapshot(
      pages: [two],
      activePage: _pageSnapshot(two, text: 'two'),
      themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
    ));
    await _settle();
    expect(container.read(strategyPageSessionProvider).deletedPage, isNull);

    queue.clearInFlight();
    await _settle();
    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, isNull);
    expect(session.activePageId, two.publicId);
  });

  for (final snapshotFirst in [false, true]) {
    test(
        "the user's own deletion says nothing over an earlier paused edit "
        '(snapshot first: $snapshotFirst)', () async {
      final one = _page('page-1', 0);
      final two = _page('page-2', 1);
      final remote = _FakeRemoteEditorNotifier(
          _editorSnapshot(
            pages: [one, two],
            activePage: _pageSnapshot(one, text: 'one'),
            themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
          ),
          pageCatalog: {
            one.publicId: _pageSnapshot(one, text: 'one'),
            two.publicId: _pageSnapshot(two, text: 'two'),
          });
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      // An earlier edit on the page that the server kept failing.
      final paused = ElementPatchOp(
        opId: 'paused-edit',
        pagePublicId: one.publicId,
        elementPublicId: 'text-${one.publicId}',
        payload: const {'value': 'kept'},
        expectedElementRevision: 1,
      );
      queue.pause(paused);
      // The server accepts the delete, and the live read drops the page,
      // before or after the ack arrives.
      queue.onFlush = () async {
        final deleting = container
            .read(strategyOpQueueProvider)
            .queuedByEntityKey
            .values
            .any((intent) => intent.pending.op is PageDeleteOp);
        if (!deleting) return;
        // The delete moves the strategy from revision 1 to 2.
        void dropPage() => remote.setSnapshot(_editorSnapshot(
              pages: [two],
              activePage: _pageSnapshot(two, text: 'two'),
              shellRevision: 2,
              themeProfileId:
                  MapThemeProfilesProvider.immutableDefaultProfileId,
            ));
        if (snapshotFirst) {
          dropPage();
          await _settle();
          queue.ackQueued(ack: (opId) => AppliedOpAck(opId: opId, revision: 2));
        } else {
          queue.ackQueued(ack: (opId) => AppliedOpAck(opId: opId, revision: 2));
          dropPage();
        }
      };

      await container.read(strategyProvider.notifier).deletePage(one.publicId);
      queue.onFlush = null;
      await _settle();

      // Before, the page read as deleted by a teammate and the switch the
      // delete planned was refused.
      final session = container.read(strategyPageSessionProvider);
      expect(session.deletedPage, isNull);
      expect(session.activePageId, two.publicId);
      expect(container.read(textProvider).single.text, 'two');
      // The paused edit still shows in the sync status.
      expect(
        container.read(strategyOpQueueProvider).pausedByEntityKey.keys,
        [EntitySyncKey.forStrategyOp(paused)],
      );
    });
  }

  test('a deletion landing while a switch flushes still tells the user',
      () async {
    final one = _page('page-1', 0, name: 'A exec');
    final two = _page('page-2', 1);
    final loadedOne = _pageSnapshot(
      one,
      settings: StrategySettings().toJson(),
      elements: const [],
    );
    final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [one, two],
          activePage: loadedOne,
          themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
        ),
        pageCatalog: {
          one.publicId: loadedOne,
          two.publicId: _pageSnapshot(two, text: 'two'),
        });
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    container.read(editorPointersProvider.notifier)
      ..markCanvas(1)
      ..down(1);
    container.read(drawingProvider.notifier)
      ..startFreeDrawing(
          const Offset(10, 20),
          CoordinateSystem.instance,
          Colors.white,
          2,
          false,
          false,
          false,
          TraversalSpeedProfile.values.first)
      ..finishFreeDrawing(const Offset(40, 50), CoordinateSystem.instance);
    container.read(editorPointersProvider.notifier).release(1);
    await _settle();
    final stroke = container.read(drawingProvider).elements.single.id;
    // The switch sends the stroke; the teammate's delete gets there first.
    queue.onFlush = () {
      queue.onFlush = null;
      remote.setSnapshot(_editorSnapshot(
        pages: [two],
        activePage: _pageSnapshot(two, text: 'two'),
        themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
      ));
    };

    await container
        .read(strategyPageSessionProvider.notifier)
        .setActivePageAnimated(
          two.publicId,
          direction: PageTransitionDirection.forward,
        );
    await _settle();

    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, (pageId: one.publicId, name: 'A exec'));
    expect(session.activePageId, one.publicId);
    expect(session.transitionState, PageTransitionState.idle);
    expect(container.read(drawingProvider).elements.map((d) => d.id), [stroke]);
  });

  test('reading the notice moves to a page that exists', () async {
    final mediaQueue = _RecordingMediaQueue();
    final (:container, :queue, :one, :two, remote: _, strokeId: _) =
        await strokeOnDeletedPage(mediaQueue: mediaQueue);
    // Work queued before the deletion goes too.
    await queue.syncDesiredGenericOp(
      entityKey: EntitySyncKey.element(one.publicId, 'old'),
      desiredOp: ElementDeleteOp(
        opId: 'old-op',
        pagePublicId: one.publicId,
        elementPublicId: 'old',
        expectedElementRevision: 1,
      ),
    );

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();
    await _settle();

    expect(left, isTrue);
    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, isNull);
    expect(session.activePageId, two.publicId);
    expect(container.read(drawingProvider).elements, isEmpty);
    expect(container.read(textProvider).single.text, 'two');
    expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    expect(container.read(strategySaveStateProvider).isDirty, isFalse);
    // Images only the dropped work placed are checked before they upload.
    expect(mediaQueue.rechecked, ['cloud-strategy']);
  });

  test("reading the notice moves on while another page's work waits", () async {
    final (:container, :queue, :two, one: _, remote: _, strokeId: _) =
        await strokeOnDeletedPage();
    // Another page's edit, waiting on the server (paused, say).
    const otherKey = EntitySyncKey.element('page-3', 'other');
    await queue.syncDesiredGenericOp(
      entityKey: otherKey,
      desiredOp: const ElementDeleteOp(
        opId: 'other-op',
        pagePublicId: 'page-3',
        elementPublicId: 'other',
        expectedElementRevision: 1,
      ),
    );

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();
    await _settle();

    expect(left, isTrue);
    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, isNull);
    expect(session.activePageId, two.publicId);
    expect(container.read(drawingProvider).elements, isEmpty);
    expect(container.read(textProvider).single.text, 'two');
    // The deleted page's work is gone; the other page's still waits.
    expect(
      container
          .read(strategyOpQueueProvider)
          .pending
          .map((pending) => pending.op.pagePublicId),
      ['page-3'],
    );
  });

  test('reading the notice keeps a map change still on its way', () async {
    final (:container, :queue, :two, one: _, remote: _, strokeId: _) =
        await strokeOnDeletedPage();
    container.read(mapProvider.notifier).updateMap(MapValue.haven);
    await queue.syncDesiredGenericOp(
      entityKey: const EntitySyncKey.strategy(),
      desiredOp: StrategyPatchOp(
        opId: 'map-change',
        expectedStrategyRevision: 1,
        payload: {'mapData': Maps.mapNames[MapValue.haven]},
      ),
    );

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();

    expect(left, isTrue);
    expect(
        container.read(strategyPageSessionProvider).activePageId, two.publicId);
    expect(container.read(mapProvider).currentMap, MapValue.haven);
  });

  test('reading the notice reads the server again after a failed read',
      () async {
    final (:container, :remote, :two, one: _, queue: _, strokeId: _) =
        await strokeOnDeletedPage();
    remote.failRead();

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();

    expect(left, isTrue);
    expect(
        container.read(strategyPageSessionProvider).activePageId, two.publicId);
  });

  test('leaving waits for work already sent for the page', () async {
    final (:container, :queue, :one, :two, remote: _, strokeId: _) =
        await strokeOnDeletedPage();
    final key = EntitySyncKey.element(one.publicId, 'sent');
    queue.holdInFlight(
      key,
      ElementDeleteOp(
        opId: 'sent-op',
        pagePublicId: one.publicId,
        elementPublicId: 'sent',
        expectedElementRevision: 1,
      ),
    );
    Future<void>.delayed(
        const Duration(milliseconds: 10), () => queue.clearInFlight());

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();
    await _settle();

    expect(left, isTrue);
    expect(
        container.read(strategyPageSessionProvider).activePageId, two.publicId);
  });

  test('work sent for the page that never comes back keeps the choice open',
      () async {
    final (:container, :queue, :one, :strokeId, remote: _, two: _) =
        await strokeOnDeletedPage();
    queue.holdInFlight(
      EntitySyncKey.element(one.publicId, 'sent'),
      ElementDeleteOp(
        opId: 'sent-op',
        pagePublicId: one.publicId,
        elementPublicId: 'sent',
        expectedElementRevision: 1,
      ),
    );

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();

    expect(left, isFalse);
    expect(container.read(strategyPageSessionProvider).deletedPage?.pageId,
        one.publicId);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
  });

  /// The server's copy once page one is restored: back in the shell, and
  /// what fresh reads return.
  void serverRestoresPageOne(
    _FakeRemoteEditorNotifier remote,
    RemotePage one,
    RemotePage two,
  ) {
    final restored = _pageSnapshot(one, text: 'one');
    remote.pageCatalog[one.publicId] = restored;
    remote.initialSnapshot = _editorSnapshot(
      pages: [one, two],
      activePage: restored,
      themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
    );
  }

  bool strokeIsQueued(ProviderContainer container, String pageId, String id) =>
      container
          .read(strategyOpQueueProvider)
          .queuedByEntityKey[EntitySyncKey.element(pageId, id)]
          ?.pending
          .op is ElementAddOp;

  test('restoring the deleted page saves the unsent stroke on it', () async {
    late _FakeRemoteEditorNotifier server;
    late RemotePage pageOne;
    late RemotePage pageTwo;
    final repository = _RestoringRepository(
        (_) => serverRestoresPageOne(server, pageOne, pageTwo));
    final (:container, :remote, :queue, :one, :two, :strokeId) =
        await strokeOnDeletedPage(repository: repository);
    (server, pageOne, pageTwo) = (remote, one, two);
    final flushesBefore = queue.flushNowCount;

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();
    await _settle();

    expect(outcome, DeletedPageRestore.restored);
    expect(repository.restoredPageIds, [one.publicId]);
    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, isNull);
    expect(session.activePageId, one.publicId);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
    // The stroke is queued against the restored page and sent now, with
    // the changes the server refused while the page was in its trash.
    expect(strokeIsQueued(container, one.publicId, strokeId), isTrue);
    expect(queue.flushNowCount, greaterThan(flushesBefore));
    expect(queue.restoredPageRetries,
        [(pageId: one.publicId, inFlight: false, refused: false)]);
    // The live read is back on the page on screen.
    expect(
      container
          .read(remoteEditorSnapshotProvider)
          .valueOrNull
          ?.activePage
          ?.page
          .publicId,
      one.publicId,
    );
  });

  test(
      'a page that can no longer be restored says so, saves nothing, and '
      'discarding still works', () async {
    final repository = _RestoringRepository(
      (_) => throw const ConvexFunctionException(
        code: ConvexErrorCode.notFound,
        rawCode: 'NOT_FOUND',
        message: 'Page not found: page-1',
      ),
    );
    final (:container, :queue, :one, :two, :strokeId, remote: _) =
        await strokeOnDeletedPage(repository: repository);

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();

    expect(outcome, DeletedPageRestore.gone);
    expect(container.read(strategyPageSessionProvider).deletedPage?.pageId,
        one.publicId);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
    expect(strokeIsQueued(container, one.publicId, strokeId), isFalse);
    expect(queue.restoredPageRetries, isEmpty);

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();
    await _settle();
    expect(left, isTrue);
    expect(
        container.read(strategyPageSessionProvider).activePageId, two.publicId);
    expect(container.read(drawingProvider).elements, isEmpty);
  });

  test('a restore that fails changes nothing and can be tried again', () async {
    late _FakeRemoteEditorNotifier server;
    late RemotePage pageOne;
    late RemotePage pageTwo;
    var offline = true;
    final repository = _RestoringRepository((_) {
      if (offline) throw StateError('Cloud connection is offline.');
      serverRestoresPageOne(server, pageOne, pageTwo);
    });
    final (:container, :remote, :queue, :one, :two, :strokeId) =
        await strokeOnDeletedPage(repository: repository);
    (server, pageOne, pageTwo) = (remote, one, two);

    final failed = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();

    expect(failed, DeletedPageRestore.failed);
    expect(container.read(strategyPageSessionProvider).deletedPage?.pageId,
        one.publicId);
    expect(
        container.read(drawingProvider).elements.map((d) => d.id), [strokeId]);
    expect(strokeIsQueued(container, one.publicId, strokeId), isFalse);
    expect(queue.restoredPageRetries, isEmpty);

    offline = false;
    final restored = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();
    await _settle();
    expect(restored, DeletedPageRestore.restored);
    expect(strokeIsQueued(container, one.publicId, strokeId), isTrue);
  });

  test('a restored page that cannot be read yet keeps the notice', () async {
    // The server restores it, but the read that follows still lacks it.
    final repository = _RestoringRepository((_) {});
    final (:container, :queue, :one, :strokeId, remote: _, two: _) =
        await strokeOnDeletedPage(repository: repository);

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();

    expect(outcome, DeletedPageRestore.failed);
    expect(container.read(strategyPageSessionProvider).deletedPage?.pageId,
        one.publicId);
    expect(strokeIsQueued(container, one.publicId, strokeId), isFalse);
    expect(queue.restoredPageRetries, isEmpty);
  });

  test(
      'a change still on its way when the page is restored is answered '
      'before refused changes are sent again', () async {
    late _FakeRemoteEditorNotifier server;
    late RemotePage pageOne;
    late RemotePage pageTwo;
    final repository = _RestoringRepository(
        (_) => serverRestoresPageOne(server, pageOne, pageTwo));
    final (:container, :remote, :queue, :one, :two, strokeId: _) =
        await strokeOnDeletedPage(repository: repository);
    (server, pageOne, pageTwo) = (remote, one, two);
    queue.holdInFlight(
      EntitySyncKey.element(one.publicId, 'sent'),
      ElementDeleteOp(
        opId: 'sent-op',
        pagePublicId: one.publicId,
        elementPublicId: 'sent',
        expectedElementRevision: 1,
      ),
    );
    Future<void>.delayed(
        const Duration(milliseconds: 10), () => queue.clearInFlight());

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();

    expect(outcome, DeletedPageRestore.restored);
    expect(queue.restoredPageRetries,
        [(pageId: one.publicId, inFlight: false, refused: false)]);
  });

  test(
      'a send whose answer was lost, refused on replay after the restore, '
      'is sent again', () async {
    late _FakeRemoteEditorNotifier server;
    late RemotePage pageOne;
    late RemotePage pageTwo;
    final repository = _RestoringRepository(
        (_) => serverRestoresPageOne(server, pageOne, pageTwo));
    final (:container, :remote, :queue, :one, :two, strokeId: _) =
        await strokeOnDeletedPage(repository: repository);
    (server, pageOne, pageTwo) = (remote, one, two);
    // Sent while the page was in the trash; the server refused it, but the
    // answer was lost, so it waits to be replayed under its own op id.
    final lost = EntitySyncKey.element(one.publicId, 'lost');
    await queue.syncDesiredGenericOp(
      entityKey: lost,
      desiredOp: ElementDeleteOp(
        opId: 'lost-op',
        pagePublicId: one.publicId,
        elementPublicId: 'lost',
        expectedElementRevision: 1,
      ),
    );
    // The flush replays it and gets the recorded refusal; the rest lands.
    queue.onFlush = () {
      final replayed = queue.state.queuedByEntityKey[lost];
      if (replayed == null) return;
      queue.state = queue.state.copyWith(
        queuedByEntityKey: {...queue.state.queuedByEntityKey}..remove(lost),
        attentionByEntityKey: {lost: replayed},
      );
      queue.ackQueued();
    };

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();

    expect(outcome, DeletedPageRestore.restored);
    // Once before the flush, and again for the refusal the replay brought.
    expect(queue.restoredPageRetries, [
      (pageId: one.publicId, inFlight: false, refused: false),
      (pageId: one.publicId, inFlight: false, refused: true),
    ]);
  });

  /// Page two on screen; page one, deleted earlier, is in the server's
  /// trash.
  Future<
      ({
        ProviderContainer container,
        _FakeStrategyOpQueueNotifier queue,
      })> pageInTrash(_RestoringRepository repository) async {
    final one = _page('page-1', 0, name: 'A exec');
    final two = _page('page-2', 1);
    final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [two],
          activePage: _pageSnapshot(two, text: 'two'),
          themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
        ),
        pageCatalog: {two.publicId: _pageSnapshot(two, text: 'two')});
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: remote,
      queue: queue,
      repository: repository,
    );
    container.read(strategyPageSessionProvider.notifier).pageWorkSettleTimeout =
        const Duration(milliseconds: 100);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    expect(
        container.read(strategyPageSessionProvider).activePageId, two.publicId);
    expect(one.publicId, 'page-1');
    return (container: container, queue: queue);
  }

  test(
      'restoring from Recently deleted sends again what the server refused '
      'while the page was in the trash, once its sends have answered',
      () async {
    final repository = _RestoringRepository((_) {});
    final (:container, :queue) = await pageInTrash(repository);
    queue.holdInFlight(
      const EntitySyncKey.element('page-1', 'sent'),
      const ElementDeleteOp(
        opId: 'sent-op',
        pagePublicId: 'page-1',
        elementPublicId: 'sent',
        expectedElementRevision: 1,
      ),
    );
    Future<void>.delayed(
        const Duration(milliseconds: 10), () => queue.clearInFlight());

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restorePageFromTrash('page-1');

    expect(outcome, DeletedPageRestore.restored);
    expect(repository.restoredPageIds, ['page-1']);
    // Once its sends answered, and again once nothing of it is queued.
    expect(queue.restoredPageRetries, [
      (pageId: 'page-1', inFlight: false, refused: false),
      (pageId: 'page-1', inFlight: false, refused: false),
    ]);
    // The page on screen stays; the restored one comes back in the list.
    expect(container.read(strategyPageSessionProvider).activePageId, 'page-2');
  });

  test(
      'a send whose answer was lost, refused on replay after a restore from '
      'Recently deleted, is sent again', () async {
    final repository = _RestoringRepository((_) {});
    final (:container, :queue) = await pageInTrash(repository);
    // Sent while the page was in the trash; the server refused it, but the
    // answer was lost, so it waits to be replayed under its own op id.
    const lost = EntitySyncKey.element('page-1', 'lost');
    await queue.syncDesiredGenericOp(
      entityKey: lost,
      desiredOp: const ElementDeleteOp(
        opId: 'lost-op',
        pagePublicId: 'page-1',
        elementPublicId: 'lost',
        expectedElementRevision: 1,
      ),
    );
    // The replay brings back the refusal the server recorded.
    Future<void>.delayed(const Duration(milliseconds: 10), () {
      final replayed = queue.state.queuedByEntityKey[lost]!;
      queue.state = queue.state.copyWith(
        queuedByEntityKey: {...queue.state.queuedByEntityKey}..remove(lost),
        attentionByEntityKey: {lost: replayed},
      );
    });

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restorePageFromTrash('page-1');

    expect(outcome, DeletedPageRestore.restored);
    expect(queue.restoredPageRetries, [
      (pageId: 'page-1', inFlight: false, refused: false),
      (pageId: 'page-1', inFlight: false, refused: true),
    ]);
  });

  test(
      'a page restored from Recently deleted whose sends never answer is '
      'restored, its refusals left to Keep mine', () async {
    final repository = _RestoringRepository((_) {});
    final (:container, :queue) = await pageInTrash(repository);
    queue.holdInFlight(
      const EntitySyncKey.element('page-1', 'sent'),
      const ElementDeleteOp(
        opId: 'sent-op',
        pagePublicId: 'page-1',
        elementPublicId: 'sent',
        expectedElementRevision: 1,
      ),
    );

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restorePageFromTrash('page-1');

    expect(outcome, DeletedPageRestore.restored);
    expect(queue.restoredPageRetries, isEmpty);
  });

  test(
      'restoring from Recently deleted says when the page is gone, and when '
      'it failed', () async {
    var gone = true;
    final repository = _RestoringRepository((_) {
      if (gone) {
        throw const ConvexFunctionException(
          code: ConvexErrorCode.notFound,
          rawCode: 'NOT_FOUND',
          message: 'Page not found: page-1',
        );
      }
      throw StateError('Cloud connection is offline.');
    });
    final (:container, :queue) = await pageInTrash(repository);
    final session = container.read(strategyPageSessionProvider.notifier);

    expect(
        await session.restorePageFromTrash('page-1'), DeletedPageRestore.gone);
    gone = false;
    expect(await session.restorePageFromTrash('page-1'),
        DeletedPageRestore.failed);
    expect(queue.restoredPageRetries, isEmpty);
  });

  test('a restore whose earlier sends never answer keeps the notice', () async {
    late _FakeRemoteEditorNotifier server;
    late RemotePage pageOne;
    late RemotePage pageTwo;
    final repository = _RestoringRepository(
        (_) => serverRestoresPageOne(server, pageOne, pageTwo));
    final (:container, :remote, :queue, :one, :two, strokeId: _) =
        await strokeOnDeletedPage(repository: repository);
    (server, pageOne, pageTwo) = (remote, one, two);
    // Sent before the delete landed; its refusal may still be on its way.
    queue.holdInFlight(
      EntitySyncKey.element(one.publicId, 'sent'),
      ElementDeleteOp(
        opId: 'sent-op',
        pagePublicId: one.publicId,
        elementPublicId: 'sent',
        expectedElementRevision: 1,
      ),
    );

    final outcome = await container
        .read(strategyPageSessionProvider.notifier)
        .restoreDeletedPage();

    expect(outcome, DeletedPageRestore.failed);
    expect(queue.restoredPageRetries, isEmpty);
    expect(container.read(strategyPageSessionProvider).deletedPage?.pageId,
        one.publicId);
  });

  test('discarding once the page is back shows its server copy', () async {
    final (:container, :remote, :one, :two, queue: _, strokeId: _) =
        await strokeOnDeletedPage();
    // Restored meanwhile: by this device's restore whose read then failed,
    // or by a teammate.
    serverRestoresPageOne(remote, one, two);

    final left = await container
        .read(strategyPageSessionProvider.notifier)
        .leaveDeletedPage();
    await _settle();

    expect(left, isTrue);
    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, isNull);
    expect(session.activePageId, one.publicId);
    expect(container.read(drawingProvider).elements, isEmpty);
    expect(container.read(textProvider).single.text, 'one');
  });

  // How the server answers this device's delete: applied at once; on a
  // replay after its first answer was lost, before the restore; or only
  // after the teammate's second delete, applied (published late) or on the
  // replay.
  for (final answer in [
    'applied',
    'replayed',
    'applied last',
    'replayed last',
  ]) {
    test(
        "a page this device deleted, restored, then deleted by a teammate "
        'still tells the user (delete $answer)', () async {
      final one = _page('page-1', 0, name: 'A exec');
      final two = _page('page-2', 1);
      final loadedOne = _pageSnapshot(
        one,
        settings: StrategySettings().toJson(),
        elements: const [],
      );
      final loadedTwo = _pageSnapshot(
        two,
        settings: StrategySettings().toJson(),
        elements: const [],
      );
      RemoteEditorSnapshot shell(
        List<RemotePage> pages,
        RemotePageSnapshot on, {
        int revision = 1,
      }) =>
          _editorSnapshot(
            pages: pages,
            activePage: on,
            shellRevision: revision,
            themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
          );
      final remote = _FakeRemoteEditorNotifier(shell([one, two], loadedOne),
          pageCatalog: {one.publicId: loadedOne, two.publicId: loadedTwo});
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      final session = container.read(strategyPageSessionProvider.notifier);
      await session.initializeForStrategy(
        strategyId: 'cloud-strategy',
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true,
      );

      // This device deletes page one; the server accepts it.
      await queue.syncDesiredGenericOp(
        entityKey: EntitySyncKey.pageDescriptor(one.publicId),
        desiredOp: PageDeleteOp(
          opId: 'delete-one',
          pagePublicId: one.publicId,
          expectedStrategyRevision: 1,
        ),
      );
      // A delete whose first answer was lost is answered on replay with a
      // no-op at the strategy's revision by then.
      if (answer == 'applied') {
        queue.ackQueued(ack: (opId) => AppliedOpAck(opId: opId, revision: 2));
      } else if (answer == 'replayed') {
        queue.ackQueued(
            ack: (opId) => NoopOpAck(opId: opId, currentRevision: 3));
      }
      remote.setSnapshot(shell([two], loadedTwo, revision: 2));
      await _settle();
      await _settle();
      // With its delete unanswered, the canvas waits on page one; otherwise
      // it moves on, and comes back once a teammate restores the page.
      final waiting = answer.endsWith('last');
      expect(container.read(strategyPageSessionProvider).activePageId,
          waiting ? one.publicId : two.publicId);
      remote.setSnapshot(shell([one, two], loadedTwo, revision: 3));
      await _settle();
      if (!waiting) await session.setActivePage(one.publicId);
      await _settle();
      expect(container.read(strategyPageSessionProvider).activePageId,
          one.publicId);

      // A teammate deletes it mid-stroke.
      container.read(editorPointersProvider.notifier)
        ..markCanvas(1)
        ..down(1);
      container.read(drawingProvider.notifier).startFreeDrawing(
          const Offset(10, 20),
          CoordinateSystem.instance,
          Colors.white,
          2,
          false,
          false,
          false,
          TraversalSpeedProfile.values.first);
      remote.setSnapshot(shell([two], loadedTwo, revision: 4));
      await _settle();
      container
          .read(drawingProvider.notifier)
          .finishFreeDrawing(const Offset(40, 50), CoordinateSystem.instance);
      container.read(editorPointersProvider.notifier).release(1);
      await _settle();
      final stroke = container.read(drawingProvider).elements.single.id;
      if (waiting) {
        queue.ackQueued(
          ack: (opId) => answer == 'applied last'
              ? AppliedOpAck(opId: opId, revision: 2)
              : NoopOpAck(opId: opId, currentRevision: 4),
        );
        await _settle();
      }

      // Before, the old delete still counted as this device's and the stroke
      // could be dropped unseen.
      expect(container.read(strategyPageSessionProvider).deletedPage?.pageId,
          one.publicId);
      await session.setActivePage(two.publicId);
      expect(container.read(strategyPageSessionProvider).activePageId,
          one.publicId);
      expect(
          container.read(drawingProvider).elements.map((d) => d.id), [stroke]);
    });
  }

  test('a deleted page with nothing unsent gives way to one that exists',
      () async {
    final one = _page('page-1', 0);
    final two = _page('page-2', 1);
    // Page one as this client writes it, so loading it changes nothing.
    final loadedOne = _pageSnapshot(
      one,
      settings: StrategySettings().toJson(),
      elements: const [],
    );
    final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [one, two],
          activePage: loadedOne,
          themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
        ),
        pageCatalog: {
          one.publicId: loadedOne,
          two.publicId: _pageSnapshot(two, text: 'two'),
        });
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    container.read(editorPointersProvider.notifier)
      ..markCanvas(1)
      ..down(1);
    remote.setSnapshot(_editorSnapshot(
      pages: [two],
      activePage: _pageSnapshot(two, text: 'two'),
      themeProfileId: MapThemeProfilesProvider.immutableDefaultProfileId,
    ));
    await _settle();
    // An edit that changed nothing still marks the page unsaved.
    await container.read(strategyProvider.notifier).notifyCloudMutation();
    container.read(editorPointersProvider.notifier).release(1);
    await _settle();
    await _settle();

    final session = container.read(strategyPageSessionProvider);
    expect(session.deletedPage, isNull);
    expect(session.activePageId, two.publicId);
    expect(container.read(textProvider).single.text, 'two');
    expect(container.read(strategySaveStateProvider).isDirty, isFalse);
  });

  test('an edit to a held lineup is checked against the version the user saw',
      () async {
    final page = _page('page-1', 0);
    final row = _lineup(page.publicId, 'a');
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before', lineups: [row]),
    ));
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    container.read(editorPointersProvider.notifier)
      ..holdEntity(1, 'a')
      ..down(1);
    // A teammate's notes edit to the same lineup lands mid-drag.
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage:
          _pageSnapshot(page, text: 'after', contentRevision: 2, lineups: [
        _editedLineup(row, (data) => data['notes'] = 'teammate notes'),
      ]),
    ));
    await _settle();
    expect(container.read(textProvider).single.text, 'after');
    expect(container.read(lineUpProvider).links.single.notes, 'remote lineup');
    container
        .read(lineUpProvider.notifier)
        .updateOriginAgentPosition('a', const Offset(400, 400));
    final ops = container
        .read(activePageLiveSyncProvider.notifier)
        .syncLocalPage(
            strategyPublicId: 'cloud-strategy', pageId: page.publicId)!;
    final op = ops[_lineupKey(page.publicId, 'a')];
    // Revision 1, not the teammate's 2: the server refuses it as a conflict
    // instead of the move silently overwriting their notes.
    expect(op, isA<LineupPatchOp>());
    expect(op!.expectedRevision, 1);
    await _settle();
  });

  group('stacking order across merges', () {
    final page = _page('page-1', 0);
    RemoteElement text(String id, int sortIndex,
            {int revision = 1, bool deleted = false}) =>
        _textElement(page.publicId, id, id,
            sortIndex: sortIndex,
            revision: revision,
            deleted: deleted,
            worldSized: true);
    RemoteEditorSnapshot snapshot(List<RemoteElement> elements,
            {int contentRevision = 1}) =>
        _editorSnapshot(
          pages: [page],
          activePage: _pageSnapshot(page,
              contentRevision: contentRevision, elements: elements),
        );

    Future<ProviderContainer> open(_FakeRemoteEditorNotifier remote) async {
      final container = await _cloudContainer(
        remote: remote,
        queue: _FakeStrategyOpQueueNotifier(),
      );
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return container;
    }

    Map<String?, StrategyOp> elementOps(ProviderContainer container) {
      final ops = container
          .read(activePageLiveSyncProvider.notifier)
          .syncLocalPage(
              strategyPublicId: 'cloud-strategy', pageId: page.publicId)!;
      return {
        for (final entry in ops.entries)
          if (entry.key.kind == EntitySyncKeyKind.element)
            entry.key.entityId: entry.value,
      };
    }

    test('an acked edit the canvas never showed is still taken', () async {
      final remote = _FakeRemoteEditorNotifier(snapshot([text('a', 0)]));
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      expect(container.read(textProvider).single.text, 'a');
      // A patch restored from the outbox lands after the page was drawn.
      final landed = _textElement(page.publicId, 'a', 'restored',
          revision: 2, worldSized: true);
      final op = ElementPatchOp(
        opId: 'restored-patch',
        pagePublicId: page.publicId,
        elementPublicId: 'a',
        expectedElementRevision: 1,
        payload: landed.payload,
        sortIndex: 0,
      );
      remote.setSnapshot(snapshot([landed], contentRevision: 2));
      final ack = AckedEntityIntent(
        entityKey: EntitySyncKey.element(page.publicId, 'a'),
        op: op,
        ack: const AppliedOpAck(opId: 'restored-patch', revision: 2),
      );
      queue.state = queue.state.copyWith(
        lastAcks: [ack.ack],
        lastAckBatch: [ack],
      );
      await _settle();
      expect(container.read(textProvider).single.text, 'restored');
      expect(elementOps(container), isEmpty);
      await _settle();
    });

    Future<(ProviderContainer, _FakeStrategyOpQueueNotifier)> openWithQueue(
        _FakeRemoteEditorNotifier remote) async {
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, queue);
    }

    void land(_FakeStrategyOpQueueNotifier queue, ElementPatchOp op, int rev) {
      final ack = AckedEntityIntent(
        entityKey: EntitySyncKey.element(page.publicId, op.elementPublicId),
        op: op,
        ack: AppliedOpAck(opId: op.opId, revision: rev),
      );
      queue.state = queue.state.copyWith(
        queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
        lastAcks: [ack.ack],
        lastAckBatch: [ack],
      );
    }

    test('grabbing an item again as its own edit lands is no conflict',
        () async {
      final remote = _FakeRemoteEditorNotifier(snapshot([text('a', 0)]));
      final (container, queue) = await openWithQueue(remote);
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(200, 200), 'a');
      await _settle();
      final sent = queue
          .state
          .queuedByEntityKey[EntitySyncKey.element(page.publicId, 'a')]!
          .pending
          .op as ElementPatchOp;
      container.read(editorPointersProvider.notifier)
        ..holdEntity(1, 'a')
        ..down(1);
      land(queue, sent, 2);
      container.read(strategySaveStateProvider.notifier).markPersisted();
      remote.setSnapshot(snapshot([
        RemoteElement(
          publicId: 'a',
          strategyPublicId: 'cloud-strategy',
          pagePublicId: page.publicId,
          elementType: 'text',
          payload: sent.payload!,
          sortIndex: 0,
          revision: 2,
          deleted: false,
        ),
      ], contentRevision: 2));
      await _settle();
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'a');
      expect(elementOps(container)['a']!.expectedRevision, 2);
      await _settle();
    });

    test('typing into an item before its own move lands is no conflict',
        () async {
      final remote = _FakeRemoteEditorNotifier(snapshot([text('a', 0)]));
      final (container, queue) = await openWithQueue(remote);
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(200, 200), 'a');
      await _settle();
      final sent = queue
          .state
          .queuedByEntityKey[EntitySyncKey.element(page.publicId, 'a')]!
          .pending
          .op as ElementPatchOp;
      // The user starts typing into it before the move is acked.
      container.read(textDraftProvider.notifier).setDraft('a', 'typing');
      land(queue, sent, 2);
      container.read(strategySaveStateProvider.notifier).markPersisted();
      remote.setSnapshot(snapshot([
        RemoteElement(
          publicId: 'a',
          strategyPublicId: 'cloud-strategy',
          pagePublicId: page.publicId,
          elementType: 'text',
          payload: sent.payload!,
          sortIndex: 0,
          revision: 2,
          deleted: false,
        ),
      ], contentRevision: 2));
      await _settle();
      container.read(textDraftProvider.notifier).commitDraft('a');
      await _settle();
      // Against the user's own move (revision 2), not the version before it.
      expect(elementOps(container)['a']!.expectedRevision, 2);
      await _settle();
    });

    test('typing into an item whose move the live read shows before its ack',
        () async {
      final remote = _FakeRemoteEditorNotifier(snapshot([text('a', 0)]));
      final (container, queue) = await openWithQueue(remote);
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(200, 200), 'a');
      await _settle();
      final sent = queue
          .state
          .queuedByEntityKey[EntitySyncKey.element(page.publicId, 'a')]!
          .pending
          .op as ElementPatchOp;
      container.read(textDraftProvider.notifier).setDraft('a', 'typing');
      remote.setSnapshot(snapshot([
        RemoteElement(
          publicId: 'a',
          strategyPublicId: 'cloud-strategy',
          pagePublicId: page.publicId,
          elementType: 'text',
          payload: sent.payload!,
          sortIndex: 0,
          revision: 2,
          deleted: false,
        ),
      ], contentRevision: 2));
      // The waiting reload starts as the queue empties, before the session
      // hears the ack.
      land(queue, sent, 2);
      await _settle();
      container.read(textDraftProvider.notifier).commitDraft('a');
      await _settle();
      expect(elementOps(container)['a']!.expectedRevision, 2);
      await _settle();
    });

    group('an edit recovered from the outbox', () {
      final key = EntitySyncKey.element(page.publicId, 'a');
      final landed = _textElement(page.publicId, 'a', 'recovered',
          revision: 2, worldSized: true);
      final recovered = ElementPatchOp(
        opId: 'recovered-edit',
        pagePublicId: page.publicId,
        elementPublicId: 'a',
        expectedElementRevision: 1,
        payload: landed.payload,
        sortIndex: 0,
      );

      /// Opens the page while [recovered] waits in the outbox, as after a
      /// restart: queued, or already sent if [inFlight].
      Future<(ProviderContainer, _FakeStrategyOpQueueNotifier)> openRecovering(
        _FakeRemoteEditorNotifier remote, {
        bool inFlight = false,
      }) async {
        final queue = _FakeStrategyOpQueueNotifier();
        final container = await _cloudContainer(remote: remote, queue: queue);
        if (inFlight) {
          queue.holdInFlight(key, recovered);
        } else {
          queue.state = queue.state.copyWith(queuedByEntityKey: {
            key: QueuedEntityIntent(
              entityKey: key,
              pending: PendingOp(op: recovered, clientId: 'test-client'),
            ),
          });
        }
        await container
            .read(strategyPageSessionProvider.notifier)
            .initializeForStrategy(
              strategyId: 'cloud-strategy',
              source: StrategySource.cloud,
              selectFirstPageIfNeeded: true,
            );
        return (container, queue);
      }

      void landRecovered(_FakeStrategyOpQueueNotifier queue) {
        final ack = AckedEntityIntent(
          entityKey: key,
          op: recovered,
          ack: const AppliedOpAck(opId: 'recovered-edit', revision: 2),
          restored: true,
        );
        queue.state = queue.state.copyWith(
          queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
          inFlightByEntityKey: const <EntitySyncKey, InFlightEntityIntent>{},
          lastAcks: [ack.ack],
          lastAckBatch: [ack],
        );
      }

      for (final ackFirst in [false, true]) {
        test(
            'landing under a held item makes the drop conflict '
            '(${ackFirst ? 'ack' : 'live read'} first)', () async {
          final remote = _FakeRemoteEditorNotifier(snapshot([text('a', 0)]));
          final (container, queue) = await openRecovering(remote);
          expect(container.read(textProvider).single.text, 'a');
          container.read(editorPointersProvider.notifier)
            ..holdEntity(1, 'a')
            ..down(1);
          if (ackFirst) landRecovered(queue);
          remote.setSnapshot(snapshot([landed], contentRevision: 2));
          if (!ackFirst) landRecovered(queue);
          await _settle();
          // Nothing re-sends the version on screen over the recovered edit.
          expect(queue.state.queuedByEntityKey[key], isNull);
          expect(container.read(textProvider).single.text, 'a');
          // The drag ends on the old text: sent against the version the user
          // saw, so the server refuses it instead of replacing 'recovered'.
          container
              .read(textProvider.notifier)
              .updatePosition(const Offset(300, 300), 'a');
          expect(elementOps(container)['a']!.expectedRevision, 1);
          await _settle();
        });
      }

      test('an edit after it lands, before the page reloads, conflicts',
          () async {
        final remote = _FakeRemoteEditorNotifier(snapshot([text('a', 0)]));
        final (container, queue) = await openRecovering(remote);
        // The live read has not caught up with the landed edit yet.
        landRecovered(queue);
        await _settle();
        expect(queue.state.queuedByEntityKey[key], isNull);
        expect(container.read(textProvider).single.text, 'a');
        container
            .read(textProvider.notifier)
            .updatePosition(const Offset(300, 300), 'a');
        expect(elementOps(container)['a']!.expectedRevision, 1);
        await _settle();
      });

      test('landing with nothing held is taken from the next read', () async {
        final remote = _FakeRemoteEditorNotifier(snapshot([text('a', 0)]));
        final (container, queue) = await openRecovering(remote);
        landRecovered(queue);
        remote.setSnapshot(snapshot([landed], contentRevision: 2));
        await _settle();
        expect(container.read(textProvider).single.text, 'recovered');
        expect(elementOps(container), isEmpty);
        await _settle();
      });

      test('while it is in flight, other edits leave it as it is', () async {
        final remote =
            _FakeRemoteEditorNotifier(snapshot([text('a', 0), text('b', 1)]));
        final (container, queue) = await openRecovering(remote, inFlight: true);
        container
            .read(textProvider.notifier)
            .updatePosition(const Offset(300, 300), 'b');
        expect(elementOps(container)['a']?.opId, 'recovered-edit');
        // The server applied it; its answer is still on the way.
        remote
            .setSnapshot(snapshot([landed, text('b', 1)], contentRevision: 2));
        await _settle();
        container
            .read(textProvider.notifier)
            .updatePosition(const Offset(320, 320), 'b');
        expect(elementOps(container)['a']?.opId, 'recovered-edit');
        await _settle();
      });

      test(
          'an edit still on its way when the user leaves for a local '
          'strategy and comes back conflicts with a drop over it', () async {
        final box = await _openStrategyBox();
        await box.put(
          'local-strategy',
          StrategyData(
            id: 'local-strategy',
            name: 'Local',
            mapData: MapValue.ascent,
            versionNumber: 1,
            lastEdited: DateTime.utc(2026),
            folderID: null,
            pages: [
              StrategyPage(
                id: 'local-page',
                name: 'Page 1',
                drawingData: const [],
                agentData: const [],
                abilityData: const [],
                textData: const [],
                imageData: const [],
                utilityData: const [],
                sortIndex: 0,
                isAttack: true,
                settings: StrategySettings(),
              ),
            ],
          ),
        );
        final settings = StrategySettings().toJson();
        RemoteEditorSnapshot withSettings(List<RemoteElement> elements,
                {int contentRevision = 1}) =>
            _editorSnapshot(
              pages: [page],
              activePage: _pageSnapshot(page,
                  contentRevision: contentRevision,
                  settings: settings,
                  elements: elements),
            );
        final remote = _FakeRemoteEditorNotifier(withSettings([text('a', 0)]));
        final repository = _HeldFirstBatchRepository();
        final container = ProviderContainer(overrides: [
          remoteEditorSnapshotProvider.overrideWith(() => remote),
          durableStrategyOutboxStoreProvider
              .overrideWithValue(MemoryDurableStrategyOutboxStore()),
          convexStrategyRepositoryProvider.overrideWithValue(repository),
          authProvider.overrideWith(_CloudReadyAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(true),
          cloudMediaAccountIdProvider.overrideWithValue('account-a'),
          cloudMediaUploadQueueProvider
              .overrideWith(() => _RecordingMediaQueue()),
        ]);
        addTearDown(container.dispose);
        container.listen(strategyPageSessionProvider, (_, __) {});
        await container.read(remoteEditorSnapshotProvider.future);
        final strategy = container.read(strategyProvider.notifier);
        final session = container.read(strategyPageSessionProvider.notifier);
        Future<void> open(String id, StrategySource source) async {
          // As openCloudStrategy and loadFromHive do. The queue stays on the
          // cloud strategy throughout: leaving for a local one never
          // switches it.
          strategy.setFromState(StrategyState(
            strategyId: id,
            strategyName: id,
            source: source,
            storageDirectory: null,
            isOpen: true,
          ));
          container.read(strategySaveStateProvider.notifier).reset();
          await session.initializeForStrategy(
            strategyId: id,
            source: source,
            selectFirstPageIfNeeded: true,
          );
        }

        container
            .read(strategyOpQueueProvider.notifier)
            .setActiveStrategy('cloud-strategy', accountId: 'account-a');
        await open('cloud-strategy', StrategySource.cloud);
        final drawnAt = container.read(textProvider).single.position;
        container
            .read(textProvider.notifier)
            .updatePosition(const Offset(200, 200), 'a');
        await repository.firstSent.future.timeout(const Duration(seconds: 5));
        final move = repository.calls.first
            .whereType<ElementPatchOp>()
            .singleWhere((op) => op.elementPublicId == 'a');

        await open('local-strategy', StrategySource.local);
        await open('cloud-strategy', StrategySource.cloud);
        // Drawn from the server, which has not applied the move yet.
        expect(container.read(textProvider).single.position, drawnAt);

        container.read(editorPointersProvider.notifier)
          ..holdEntity(1, 'a')
          ..down(1);
        remote.setSnapshot(withSettings([
          RemoteElement(
            publicId: 'a',
            strategyPublicId: 'cloud-strategy',
            pagePublicId: page.publicId,
            elementType: 'text',
            payload: move.payload!,
            sortIndex: 0,
            revision: 2,
            deleted: false,
          ),
        ], contentRevision: 2));
        // The first op for it sent from here on.
        final nextEdit = repository.nextEditOf('a');
        repository.landFirst();
        await _settle();
        await _settle();
        final landing = container
            .read(strategyOpQueueProvider)
            .lastAckBatch
            .singleWhere((acked) => acked.entityKey == key);
        expect(container.read(textProvider).single.position, drawnAt);

        container
            .read(textProvider.notifier)
            .updatePosition(const Offset(300, 300), 'a');
        final sent = await nextEdit;
        // Against the version the user saw: the server refuses it instead
        // of replacing the move.
        expect(sent.expectedRevision, 1);
        // The queue said the move it accepted was not the canvas's work.
        expect(landing.restored, isTrue);
        await _settle();
      });
    });

    test('moving past an element with the same sortIndex is sent', () async {
      final container = await open(
          _FakeRemoteEditorNotifier(snapshot([text('a', 3), text('b', 3)])));
      expect(elementOps(container), isEmpty);
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'a');
      final ops = elementOps(container);
      expect(ops.keys, ['a']);
      expect((ops['a']! as ElementPatchOp).sortIndex, 4);
      await _settle();
    });

    test('a teammate restacking a held item re-sends nothing else', () async {
      final remote =
          _FakeRemoteEditorNotifier(snapshot([text('a', 0), text('b', 1)]));
      final container = await open(remote);
      container.read(textDraftProvider.notifier).setDraft('a', 'typing');
      // The teammate brings 'a' forward and adds 'c'.
      remote.setSnapshot(snapshot(
          [text('b', 1), text('a', 2, revision: 2), text('c', 3)],
          contentRevision: 2));
      await _settle();
      expect(container.read(textProvider).map((t) => t.id), ['b', 'a', 'c']);
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'b');
      final ops = elementOps(container);
      // The user's move, and the open draft on 'a' (the user's words): sent
      // at the revision they saw, so it conflicts with the teammate's edit,
      // and at the server's place, not restacked. 'c' is not re-sent.
      expect(ops.keys.toSet(), {'b', 'a'});
      expect(ops['a']!.expectedRevision, 1);
      expect((ops['a']! as ElementPatchOp).sortIndex, 2);
      await _settle();
    });

    test('a held item the server deleted re-sends nothing else', () async {
      final remote = _FakeRemoteEditorNotifier(snapshot(
          [text('mover', 0), text('a', 1), text('held', 2), text('b', 3)]));
      final container = await open(remote);
      container.read(editorPointersProvider.notifier)
        ..holdEntity(1, 'held')
        ..down(1);
      remote.setSnapshot(snapshot([
        text('mover', 0),
        text('held', 2, revision: 2, deleted: true),
        text('b', 3),
        text('a', 4, revision: 2),
      ], contentRevision: 2));
      await _settle();
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(400, 400), 'mover');
      expect(elementOps(container).keys, ['mover']);
      await _settle();
    });
  });

  group('holding an item while a teammate edits the page', () {
    RemotePageSnapshot texts(
      RemotePage page,
      Map<String, (String, int)> byId, {
      required int contentRevision,
    }) =>
        _pageSnapshot(
          page,
          contentRevision: contentRevision,
          elements: [
            for (final (index, entry) in byId.entries.indexed)
              _textElement(page.publicId, entry.key, entry.value.$1,
                  revision: entry.value.$2, sortIndex: index, worldSized: true),
          ],
        );

    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)>
        open() async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: texts(
            page, {'held': ('held v1', 1), 'other': ('other v1', 1)},
            contentRevision: 1),
      ));
      final container = await _cloudContainer(
        remote: remote,
        queue: _FakeStrategyOpQueueNotifier(),
      );
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      // The app-wide scope sees the press last, after the item's layer.
      container.read(editorPointersProvider.notifier)
        ..holdEntity(1, 'held')
        ..down(1);
      return (container, remote, page);
    }

    String textOf(ProviderContainer container, String id) =>
        container.read(textProvider).firstWhere((text) => text.id == id).text;

    test('only the held item waits; it updates on release', () async {
      final (container, remote, page) = await open();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: texts(
            page, {'held': ('held v2', 2), 'other': ('other v2', 2)},
            contentRevision: 2),
      ));
      await _settle();
      expect(textOf(container, 'other'), 'other v2');
      expect(textOf(container, 'held'), 'held v1');

      container.read(editorPointersProvider.notifier).release(1);
      await _settle();
      expect(textOf(container, 'held'), 'held v2');
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    });

    test('an edit committed to it is checked against the version the user saw',
        () async {
      final (container, remote, page) = await open();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: texts(
            page, {'held': ('held v2', 2), 'other': ('other v1', 1)},
            contentRevision: 2),
      ));
      await _settle();
      // The drag ends: the move commits before the hold releases.
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'held');
      container.read(editorPointersProvider.notifier).release(1);
      await _settle();

      final sent = container
          .read(strategyOpQueueProvider)
          .pending
          .singleWhere((item) => item.op.entityPublicId == 'held');
      // Revision 1, not the teammate's 2: the server rejects it as a
      // conflict instead of the move silently overwriting their edit.
      expect(sent.op.expectedRevision, 1);
    });

    test('a teammate deleting it leaves it under the pointer until release',
        () async {
      final (container, remote, page) = await open();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: texts(page, {'other': ('other v1', 1)}, contentRevision: 2),
      ));
      await _settle();
      expect(container.read(textProvider).map((text) => text.id),
          containsAll(['held', 'other']));

      container.read(editorPointersProvider.notifier).release(1);
      await _settle();
      expect(container.read(textProvider).map((text) => text.id), ['other']);
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    });

    test('a teammate deleting an item re-sends no other item', () async {
      final (container, remote, page) = await open();
      container.read(editorPointersProvider.notifier).release(1);
      await _settle();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        // The server keeps 'other' at sortIndex 1; it never renumbers.
        activePage: _pageSnapshot(page, contentRevision: 2, elements: [
          _textElement(page.publicId, 'other', 'other v1',
              sortIndex: 1, worldSized: true),
        ]),
      ));
      await _settle();
      final ops = container
          .read(activePageLiveSyncProvider.notifier)
          .syncLocalPage(
              strategyPublicId: 'cloud-strategy', pageId: page.publicId)!;
      expect(
          ops.keys
              .where((key) => key.kind == EntitySyncKeyKind.element)
              .map((key) => key.entityId),
          isEmpty);
      await _settle();
    });

    test('moving an item brings it forward and sends only its sortIndex',
        () async {
      final (container, remote, page) = await open();
      container.read(editorPointersProvider.notifier).release(1);
      await _settle();
      // A move re-appends the item: it now stacks above 'other'.
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'held');
      final ops = container
          .read(activePageLiveSyncProvider.notifier)
          .syncLocalPage(
              strategyPublicId: 'cloud-strategy', pageId: page.publicId)!;
      final elementOps = {
        for (final entry in ops.entries)
          if (entry.key.kind == EntitySyncKeyKind.element)
            entry.key.entityId: entry.value,
      };
      expect(elementOps.keys, ['held']);
      expect((elementOps['held']! as ElementPatchOp).sortIndex, 2);
      await _settle();

      // The move lands and comes back: it stays on top.
      final queue = container.read(strategyOpQueueProvider.notifier)
          as _FakeStrategyOpQueueNotifier;
      queue.state = queue.state.copyWith(
          queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{});
      container.read(strategySaveStateProvider.notifier).markPersisted();
      final moved =
          container.read(textProvider).firstWhere((text) => text.id == 'held');
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, contentRevision: 2, elements: [
          _textElement(page.publicId, 'other', 'other v1',
              sortIndex: 1, worldSized: true),
          RemoteElement(
            publicId: 'held',
            strategyPublicId: 'cloud-strategy',
            pagePublicId: page.publicId,
            elementType: 'text',
            payload: cloudElementPayload(
                kind: 'text', data: {...moved.toJson(), 'elementType': 'text'}),
            sortIndex: 2,
            revision: 2,
            deleted: false,
          ),
        ]),
      ));
      await _settle();
      expect(container.read(textProvider).map((text) => text.id),
          ['other', 'held']);
    });

    test('an open text draft holds its text the same way', () async {
      final (container, remote, page) = await open();
      container.read(editorPointersProvider.notifier).release(1);
      await _settle();
      container.read(textDraftProvider.notifier).setDraft('held', 'typing');
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: texts(
            page, {'held': ('held v2', 2), 'other': ('other v2', 2)},
            contentRevision: 2),
      ));
      await _settle();
      expect(textOf(container, 'other'), 'other v2');
      expect(textOf(container, 'held'), 'held v1');
      expect(container.read(textDraftProvider)['held'], 'typing');

      container.read(textDraftProvider.notifier).clearDraft('held');
      await _settle();
      expect(textOf(container, 'held'), 'held v2');
    });
  });

  group('holding a lineup spot while a teammate edits the page', () {
    const moved = Offset(500, 500);

    /// Lineup `a` from origin `a`, lineup `a2` from the same origin, and
    /// lineup `b` on spots of its own, each with its origin at [at].
    List<RemoteLineup> lineups(
      RemotePage page, {
      Offset at = const Offset(10, 20),
      int revision = 1,
      String notes = 'remote lineup',
    }) =>
        [
          _lineupRow(page.publicId, 'link-a',
              origin: _originJson('a', at),
              landing: _landingJson('landing-a'),
              notes: notes,
              revision: revision),
          _lineupRow(page.publicId, 'link-a2',
              origin: _originJson('a', at),
              landing: _landingJson('landing-a2', const Offset(60, 60)),
              notes: notes,
              revision: revision,
              sortIndex: 1),
          _lineupRow(page.publicId, 'link-b',
              origin: _originJson('b', at),
              landing: _landingJson('landing-b'),
              notes: notes,
              revision: revision,
              sortIndex: 2),
        ];

    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)>
        open() async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, text: 'before', lineups: lineups(page)),
      ));
      final container = await _cloudContainer(
        remote: remote,
        queue: _FakeStrategyOpQueueNotifier(),
      );
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, remote, page);
    }

    Offset originAt(ProviderContainer container, String id) =>
        container.read(lineUpProvider).originById(id)!.agent.position;

    test('dragging a spot holds only the lineups on it until release',
        () async {
      final (container, remote, page) = await open();
      container.read(editorPointersProvider.notifier)
        ..holdEntity(1, 'landing-a')
        ..down(1);

      // A teammate moves every origin, edits every lineup's notes, and adds
      // a lineup to the held lineup's origin.
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage:
            _pageSnapshot(page, text: 'after', contentRevision: 2, lineups: [
          ...lineups(page, at: moved, revision: 2, notes: 'teammate notes'),
          _lineupRow(page.publicId, 'link-c',
              origin: _originJson('a', moved),
              landing: _landingJson('landing-c', const Offset(90, 90)),
              sortIndex: 3),
        ]),
      ));
      await _settle();

      // The dragged landing's lineup waits, and so does every lineup that
      // shares a spot with it: their shared origin is drawn once.
      final lineUps = container.read(lineUpProvider);
      expect(container.read(textProvider).single.text, 'after');
      expect(originAt(container, 'a'), const Offset(10, 20));
      expect(lineUps.linkById('link-a')!.notes, 'remote lineup');
      expect(lineUps.linkById('link-a2')!.notes, 'remote lineup');
      expect(lineUps.linkById('link-c'), isNull);
      // The unrelated lineup on the same page takes the change at once.
      expect(originAt(container, 'b'), moved);
      expect(lineUps.linkById('link-b')!.notes, 'teammate notes');

      container.read(editorPointersProvider.notifier).release(1);
      await _settle();

      final released = container.read(lineUpProvider);
      expect(originAt(container, 'a'), moved);
      expect(released.linkById('link-a')!.notes, 'teammate notes');
      expect(released.linkById('link-a2')!.notes, 'teammate notes');
      expect(released.links.map((link) => link.id),
          ['link-a', 'link-a2', 'link-b', 'link-c']);
      expect(released.origins, hasLength(2));
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    });

    test('a placement pinned to an origin holds only that origin\'s lineups',
        () async {
      final (container, remote, page) = await open();
      container.read(lineUpProvider.notifier).startFromOrigin('a');
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page,
            text: 'after',
            contentRevision: 2,
            lineups: lineups(page, at: moved, revision: 2)),
      ));
      await _settle();
      expect(container.read(textProvider).single.text, 'after');
      expect(originAt(container, 'a'), const Offset(10, 20));
      expect(originAt(container, 'b'), moved);
      expect(container.read(lineUpProvider).placement?.pinnedOriginId, 'a');

      container.read(lineUpProvider.notifier).clearPlacement();
      await _settle();
      expect(originAt(container, 'a'), moved);
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    });
  });

  for (final startDuringLoad in [false, true]) {
    test(
        'remote hydration waits for pointer, started during load=$startDuringLoad',
        () async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, text: 'before'),
      ));
      final container = await _cloudContainer(
        remote: remote,
        queue: _FakeStrategyOpQueueNotifier(),
      );
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      final pointers = container.read(editorPointersProvider.notifier);
      if (!startDuringLoad) pointers.down(1);
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, text: 'after', contentRevision: 2),
      ));
      if (startDuringLoad) pointers.down(1);
      await _settle();
      expect(container.read(textProvider).single.text, 'before');
      expect(container.read(activePageLiveSyncProvider).hydratedPageId,
          page.publicId);
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, text: 'latest', contentRevision: 3),
      ));
      await _settle();
      expect(container.read(textProvider).single.text, 'before');
      pointers.release(1);
      await _settle();
      expect(container.read(textProvider).single.text, 'latest');
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    });
  }

  test('a page switch supersedes a remote reload already in progress',
      () async {
    final one = _page('page-1', 0);
    final two = _page('page-2', 1);
    final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [one, two],
          activePage: _pageSnapshot(one, text: 'one'),
        ),
        pageCatalog: {
          one.publicId: _pageSnapshot(one, text: 'one'),
          two.publicId: _pageSnapshot(two, text: 'two'),
        });
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
        strategyId: 'cloud-strategy',
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true);
    remote.setSnapshot(_editorSnapshot(
        pages: [one, two],
        activePage: _pageSnapshot(one, text: 'stale', contentRevision: 2)));
    await session.setActivePage(two.publicId);
    await _settle();
    expect(
        container.read(strategyPageSessionProvider).activePageId, two.publicId);
    expect(container.read(textProvider).single.text, 'two');
  });

  test('remote hydration preserves and queues a committed text draft',
      () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    const textId = 'text-page-1';
    container.read(textDraftProvider.notifier).setDraft(textId, 'local-intent');
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage:
          _pageSnapshot(page, text: 'remote-change', contentRevision: 2),
    ));
    await _settle();

    container.read(textDraftProvider.notifier).commitDraft(textId);
    await _settle();

    expect(container.read(textProvider).single.text, 'local-intent');
    expect(container.read(textDraftProvider), isEmpty);
    final pending = container.read(strategyOpQueueProvider).pending;
    expect(pending, isNotEmpty);
    expect(
      pending.any((item) =>
          item.op.entityPublicId == textId &&
          item.op.payload.toString().contains('local-intent')),
      isTrue,
    );
  });

  test('rejected local intent stays visible and requires attention', () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'server-before'),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(textProvider.notifier).commitText(
          'text-page-1',
          'local-losing-intent',
        );
    await _settle();
    final op = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityPublicId == 'text-page-1');

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        text: 'server-winner',
        contentRevision: 2,
      ),
    ));
    queue.reject(op);
    await _settle();

    expect(container.read(textProvider).single.text, 'local-losing-intent');
    expect(container.read(strategyOpQueueProvider).needsAttention, isTrue);
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      hasLength(1),
    );
    expect(container.read(strategyConflictProvider), hasLength(1));
    expect(container.read(strategyConflictProvider).single.opId, op.opId);
  });

  test(
      'using cloud after a conflict replaces the canvas without resubmitting it',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(page.publicId, 'text-page-1', 'server-before',
              worldSized: true),
        ],
      ),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    const textId = 'text-page-1';
    const key = EntitySyncKey.element('page-1', textId);
    container.read(textProvider.notifier).commitText(
          textId,
          'local-losing-intent',
        );
    await _settle();
    final rejectedOp = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityPublicId == textId);
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(page.publicId, textId, 'server-winner',
              worldSized: true),
        ],
        contentRevision: 2,
      ),
    ));
    queue.reject(rejectedOp);
    await _settle();
    container
        .read(textDraftProvider.notifier)
        .setDraft(textId, 'draft-in-progress');
    container
        .read(textDraftProvider.notifier)
        .setDraft('unrelated-text', 'keep-this-draft');

    final resolved = await container
        .read(strategyPageSessionProvider.notifier)
        .useCloudVersionsForRejected();
    await _settle();

    expect(resolved, isTrue);
    expect(container.read(textProvider).single.text, 'server-winner');
    expect(container.read(textDraftProvider), {
      'unrelated-text': 'keep-this-draft',
    });
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      isNot(contains(key)),
    );
    expect(
      container.read(activePageLiveSyncProvider).overlayByEntityKey,
      isNot(contains(key)),
    );
    expect(
      container
          .read(strategyOpQueueProvider)
          .pending
          .map((pending) => pending.op.entityPublicId),
      isNot(contains(textId)),
    );

    container.read(textDraftProvider.notifier).clearDraft(textId);
    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );
    expect(desired, isNotNull);
    expect(desired, isNot(contains(key)));
    await queue.syncDesiredOpsForPage(
      pageId: page.publicId,
      desiredOpsByEntityKey: desired!,
      flushImmediately: false,
    );
    expect(
      container
          .read(strategyOpQueueProvider)
          .pending
          .map((pending) => pending.op.entityPublicId),
      isNot(contains(textId)),
    );
  });

  for (final failDiscard in [false, true]) {
    test('use cloud preserves unrelated edits when discard fails=$failDiscard',
        () async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, elements: [
          _textElement(page.publicId, 'conflicted', 'server-before',
              worldSized: true),
          _textElement(page.publicId, 'unrelated', 'server-original',
              worldSized: true),
        ]),
      ));
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      final session = container.read(strategyPageSessionProvider.notifier);
      queue.failDiscard = failDiscard;
      await session.initializeForStrategy(
        strategyId: 'cloud-strategy',
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true,
      );
      container
          .read(textProvider.notifier)
          .commitText('conflicted', 'local-loser');
      await _settle();
      final rejected = container
          .read(strategyOpQueueProvider)
          .pending
          .map((p) => p.op)
          .firstWhere((op) => op.entityPublicId == 'conflicted');
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, contentRevision: 2, elements: [
          _textElement(page.publicId, 'conflicted', 'server-winner',
              worldSized: true),
          _textElement(page.publicId, 'unrelated', 'server-original',
              worldSized: true),
        ]),
      ));
      queue.reject(rejected);
      await _settle();
      container
          .read(textProvider.notifier)
          .commitText('unrelated', 'keep-my-edit');
      container.read(mapProvider.notifier).fromHive(MapValue.haven, true);
      container
          .read(strategyThemeProvider.notifier)
          .fromStrategy(profileId: 'local-theme');
      await _settle();
      expect(container.read(strategyOpQueueProvider).queuedByEntityKey,
          contains(const EntitySyncKey.element('page-1', 'unrelated')));
      expect(await session.useCloudVersionsForRejected(), !failDiscard);
      await _settle();
      final canvas = {
        for (final text in container.read(textProvider)) text.id: text.text
      };
      final desired =
          container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: 'page-1',
              )!;
      await queue.syncDesiredOpsForPage(
          pageId: 'page-1', desiredOpsByEntityKey: desired);
      expect(canvas['unrelated'], 'keep-my-edit');
      expect(
          canvas['conflicted'], failDiscard ? 'local-loser' : 'server-winner');
      expect(container.read(mapProvider).currentMap, MapValue.haven);
      expect(container.read(strategyThemeProvider).profileId, 'local-theme');
      final queued = container.read(strategyOpQueueProvider).queuedByEntityKey;
      expect(
          queued[const EntitySyncKey.element('page-1', 'unrelated')]!
              .pending
              .op
              .payload
              .toString(),
          contains('keep-my-edit'));
      expect(queued,
          isNot(contains(const EntitySyncKey.element('page-1', 'conflicted'))));
    });
  }

  test('using cloud with no remaining attention is a silent no-op', () async {
    final page = _page('page-1', 0);
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, text: 'remote'),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );

    expect(await session.useCloudVersionsForRejected(), isTrue);
  });

  test('failed cloud hydration keeps the rejected work available', () async {
    final page = _page('page-1', 0);
    const textId = 'text-page-1';
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'before'),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );
    container.read(textProvider.notifier).commitText(textId, 'local-edit');
    await _settle();
    final rejectedOp = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityPublicId == textId);
    final malformedLineup = RemoteLineup(
      publicId: 'bad-lineup',
      strategyPublicId: 'cloud-strategy',
      pagePublicId: page.publicId,
      payload: const {
        'kind': 'lineup',
        'payloadVersion': 1,
        'data': {'id': 'bad-lineup', 'broken': true},
      },
      sortIndex: 0,
      revision: 1,
      deleted: false,
    );
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(page.publicId, textId, 'server-winner'),
        ],
        lineups: [malformedLineup],
      ),
    ));
    queue.reject(rejectedOp);
    await _settle();

    await expectLater(
      session.useCloudVersionsForRejected(),
      throwsA(isA<FormatException>()),
    );

    final key = EntitySyncKey.element(page.publicId, textId);
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      contains(key),
    );
    expect(
      container.read(activePageLiveSyncProvider).overlayByEntityKey,
      contains(key),
    );
  });

  test('using cloud for a strategy conflict restores remote map and theme',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
      shellRevision: 3,
      mapData: Maps.mapNames[MapValue.haven],
      themeProfileId: 'remote-theme',
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(mapProvider.notifier).updateMap(MapValue.ascent);
    container.read(strategyThemeProvider.notifier).setProfile('local-theme');
    await _settle();
    final rejectedOp = container
        .read(strategyOpQueueProvider)
        .pending
        .map((pending) => pending.op)
        .firstWhere((op) => op.entityType == StrategyOpEntityType.strategy);
    queue.reject(rejectedOp);
    await _settle();

    final resolved = await container
        .read(strategyPageSessionProvider.notifier)
        .useCloudVersionsForRejected();
    await _settle();

    expect(resolved, isTrue);
    expect(container.read(mapProvider).currentMap, MapValue.haven);
    expect(container.read(strategyThemeProvider).profileId, 'remote-theme');
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      isNot(contains(const EntitySyncKey.strategy())),
    );

    await container
        .read(strategyProvider.notifier)
        .notifyCloudStrategyMutation(flushImmediately: false);
    expect(
      container
          .read(strategyOpQueueProvider)
          .pending
          .map((pending) => pending.op.entityType),
      isNot(contains(StrategyOpEntityType.strategy)),
    );
  });

  test('inactive page shell update does not rehydrate the active canvas',
      () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final before = _editorSnapshot(
      pages: [pageOne, pageTwo],
      activePage: _pageSnapshot(pageOne, text: 'remote'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local', position: const Offset(5, 5))..text = 'local',
    ]);

    remote.setSnapshot(_editorSnapshot(
      pages: [pageOne, _page('page-2', 1, revision: 2, name: 'Renamed')],
      activePage: _pageSnapshot(pageOne, text: 'remote'),
      shellRevision: 2,
    ));
    await _settle();
    expect(container.read(textProvider).single.text, 'local');
  });

  test('outbound diff waits for the matching active-page remote base',
      () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [pageOne, pageTwo],
      activePage: _pageSnapshot(pageTwo, text: 'remote-two'),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local-one', position: const Offset(5, 5))
        ..text = 'local-one',
    ]);

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: 'page-1',
            );

    expect(desired, isNull);
  });

  test('final side is emitted while the opposite side is in flight', () async {
    final page = _page('page-1', 0, revision: 7);
    final queue = _FakeStrategyOpQueueNotifier();
    const key = EntitySyncKey.pageDescriptor('page-1');
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
      )),
      queue: queue,
    );
    container.read(strategyOpQueueProvider);
    final sync = container.read(activePageLiveSyncProvider.notifier)
      ..markPageHydrated(
        strategyPublicId: 'cloud-strategy',
        pageId: page.publicId,
        snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
      );
    // The user switches to defense, and that is sent.
    container.read(mapProvider.notifier).setAttack(false);
    final defense = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    )![key]!;
    expect(defense.payload, {'isAttack': false});
    queue.holdInFlight(key, defense);
    // They switch back while it is on its way.
    container.read(mapProvider.notifier).setAttack(true);

    final desired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    );

    final sideOp = desired![key] as PagePatchOp;
    expect(sideOp.payload, {'isAttack': true});
    expect(sideOp.expectedPageRevision, 7);
    expect(
      desired.keys.where((candidate) =>
          candidate.kind == EntitySyncKeyKind.element ||
          candidate.kind == EntitySyncKeyKind.lineup),
      isEmpty,
    );
  });

  test('final text is emitted while an earlier edit is in flight', () async {
    final page = _page('page-1', 0);
    const textId = 'text-page-1';
    final remoteText = _textElement(
      page.publicId,
      textId,
      'before',
      worldSized: true,
    );
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, elements: [remoteText]),
      )),
      queue: queue,
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    const key = EntitySyncKey.element('page-1', textId);
    final firstEdit = ElementPatchOp(
      opId: 'first-edit-in-flight',
      elementPublicId: textId,
      pagePublicId: page.publicId,
      payload: _textElement(
        page.publicId,
        textId,
        'first-edit',
        worldSized: true,
      ).payload,
      sortIndex: 0,
      expectedElementRevision: 1,
    );
    queue.holdInFlight(key, firstEdit);
    container.read(textDraftProvider.notifier).setDraft(textId, 'final-edit');

    final beforeAck =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            )![key] as ElementPatchOp;
    expect(beforeAck.payload.toString(), contains('final-edit'));
    expect(beforeAck.expectedElementRevision, 1);

    container.read(activePageLiveSyncProvider.notifier).recordAckBatch([
      AckedEntityIntent(
        entityKey: key,
        op: firstEdit,
        ack: const AppliedOpAck(
          opId: 'first-edit-in-flight',
          revision: 2,
        ),
      ),
    ]);
    queue.clearInFlight();

    final afterAck =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            )![key] as ElementPatchOp;
    expect(afterAck.payload.toString(), contains('final-edit'));
    expect(afterAck.expectedElementRevision, 2);
  });

  test('an ack after leaving a page advances its retained overlay revision',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, elements: [
        _textElement('page-1', 'text-a', 'before', worldSized: true),
      ]),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final sync = container.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
        strategyPublicId: 'cloud-strategy',
        pageId: 'page-1',
        snapshot: remote.initialSnapshot);
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-a', position: const Offset(10, 20))
        ..text = 'my edit'
        ..markSizeAsWorld(),
    ]);
    const key = EntitySyncKey.element('page-1', 'text-a');
    final op = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: 'page-1',
    )![key]!;
    sync.setContext(strategyPublicId: 'cloud-strategy', activePageId: 'page-2');
    sync.recordAckBatch([
      AckedEntityIntent(
          entityKey: key, op: op, ack: AppliedOpAck(opId: op.opId, revision: 2))
    ]);
    expect(
        container
            .read(activePageLiveSyncProvider)
            .overlayByEntityKey[key]!
            .baseRevision,
        2);

    remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, elements: [
          _textElement('page-1', 'text-a', 'my edit',
              revision: 2, worldSized: true),
        ])));
    sync.markPageHydrated(
        strategyPublicId: 'cloud-strategy',
        pageId: 'page-1',
        snapshot: remote.initialSnapshot);
    container.read(textProvider.notifier).commitText('text-a', 'next edit');
    final next = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: 'page-1',
    )![key] as ElementPatchOp;
    expect(next.expectedElementRevision, 2);
    expect(next.payload.toString(), contains('next edit'));
  });

  test('rename acks preserve the side baseline during a remote side change',
      () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
    ));
    final container = await _syncContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final sync = container.read(activePageLiveSyncProvider.notifier);
    container.read(mapProvider.notifier).fromHive(MapValue.ascent, true);
    sync.markPageHydrated(
        strategyPublicId: 'cloud-strategy',
        pageId: 'page-1',
        snapshot: remote.initialSnapshot);
    const key = EntitySyncKey.pageDescriptor('page-1');
    sync.recordAckBatch([
      const AckedEntityIntent(
        entityKey: key,
        op: PagePatchOp(
            opId: 'rename',
            pagePublicId: 'page-1',
            payload: {'name': 'Renamed'},
            expectedPageRevision: 1),
        ack: AppliedOpAck(opId: 'rename', revision: 2),
      )
    ]);
    final changed =
        _page('page-1', 0, revision: 3, name: 'Renamed', isAttack: false);
    remote.setSnapshot(_editorSnapshot(
      pages: [changed],
      activePage: _pageSnapshot(changed),
    ));
    final desired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: 'page-1',
    )!;
    expect(desired, isNot(contains(key)));
    expect(
        sync
            .projectPageState(
              strategyPublicId: 'cloud-strategy',
              pageId: 'page-1',
            )!
            .isAttack,
        isFalse);
  });

  test('a final delete is emitted behind an in-flight local add', () async {
    final page = _page('page-1', 0);
    const textId = 'new-local-text';
    const key = EntitySyncKey.element('page-1', textId);
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page),
      )),
      queue: queue,
    );
    final sync = container.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
      snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: textId, position: const Offset(10, 20))
        ..text = 'first'
        ..markSizeAsWorld(),
    ]);

    final firstDesired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    );
    final add = firstDesired![key] as ElementAddOp;
    queue.holdInFlight(key, add);
    container.read(textProvider.notifier).removeText(textId);

    final finalDesired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    );

    final delete = finalDesired![key] as ElementDeleteOp;
    expect(delete.expectedElementRevision, 0);
  });

  test('restart retains a queued add missing from canvas and remote', () async {
    final page = _page('page-1', 0);
    const textId = 'queued-before-restart';
    const key = EntitySyncKey.element('page-1', textId);
    final add = ElementAddOp(
      opId: 'add-before-restart',
      elementPublicId: textId,
      pagePublicId: page.publicId,
      payload: _textElement(page.publicId, textId, 'unsent').payload,
      sortIndex: 0,
    );
    final store = MemoryDurableStrategyOutboxStore();
    final firstContainer = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      strategyOutboxSessionProvider.overrideWithValue(
        const StrategyOutboxSession(
          accountId: null,
          isReady: false,
          hasAuthIncident: false,
        ),
      ),
    ]);
    firstContainer
        .read(cloudCollabModeProvider.notifier)
        .setForceLocalFallback(true);
    final firstQueue = firstContainer.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('cloud-strategy', accountId: 'account-a');
    await firstQueue.enqueue(add, flushImmediately: false);
    expect(store.load().records.single.pending.op.opId, 'add-before-restart');
    firstContainer.dispose();

    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page),
    ));
    final restarted = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      strategyOutboxSessionProvider.overrideWithValue(
        const StrategyOutboxSession(
          accountId: null,
          isReady: false,
          hasAuthIncident: false,
        ),
      ),
      remoteEditorSnapshotProvider.overrideWith(() => remote),
    ]);
    addTearDown(restarted.dispose);
    restarted
        .read(cloudCollabModeProvider.notifier)
        .setForceLocalFallback(true);
    final restartedQueue = restarted.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('cloud-strategy', accountId: 'account-a');
    await restarted.read(remoteEditorSnapshotProvider.future);
    final sync = restarted.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
      snapshot: restarted.read(remoteEditorSnapshotProvider).requireValue!,
    );

    final desired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: page.publicId,
    );

    final retained = desired![key] as ElementAddOp;
    expect(retained.opId, 'add-before-restart');
    expect(retained.payload, add.payload);
    await restartedQueue.syncDesiredOpsForPage(
      pageId: page.publicId,
      desiredOpsByEntityKey: desired,
      flushImmediately: false,
    );
    expect(
      restarted
          .read(strategyOpQueueProvider)
          .queuedByEntityKey[key]!
          .pending
          .op,
      isA<ElementAddOp>(),
    );
    final durable = store.load().records.singleWhere(
          (record) => record.entityKey == key,
        );
    expect(durable.pending.op.opId, 'add-before-restart');
  });

  test('hydration keeps the exact snapshot used to load the canvas', () async {
    const textId = 'text-page-1';
    final hydratedPage = _page('page-1', 0);
    final hydratedSnapshot = _editorSnapshot(
      pages: [hydratedPage],
      activePage: _pageSnapshot(
        hydratedPage,
        elements: [
          _textElement(
            hydratedPage.publicId,
            textId,
            'hydrated-value',
            worldSized: true,
          ),
        ],
      ),
    );
    final newerPage = _page('page-1', 0, revision: 2);
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [newerPage],
        activePage: _pageSnapshot(
          newerPage,
          elements: [
            _textElement(
              newerPage.publicId,
              textId,
              'newer-remote-value',
              revision: 2,
              worldSized: true,
            ),
          ],
        ),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    final hydratedText = PlacedText(
      id: textId,
      position: const Offset(10, 20),
    )
      ..text = 'hydrated-value'
      ..markSizeAsWorld();
    container.read(textProvider.notifier).fromHive([hydratedText]);

    final sync = container.read(activePageLiveSyncProvider.notifier);
    sync.markPageHydrated(
      strategyPublicId: 'cloud-strategy',
      pageId: hydratedPage.publicId,
      snapshot: hydratedSnapshot,
    );
    container.read(textDraftProvider.notifier).setDraft(textId, 'local-edit');

    final desired = sync.syncLocalPage(
      strategyPublicId: 'cloud-strategy',
      pageId: hydratedPage.publicId,
    );

    final op = desired![EntitySyncKey.element(hydratedPage.publicId, textId)]
        as ElementPatchOp;
    expect(op.payload.toString(), contains('local-edit'));
    expect(op.expectedElementRevision, 1);
  });

  test('side switch authors exactly one Page descriptor operation', () async {
    final page = _page('page-1', 0, revision: 11);
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          settings: const {
            'agentSize': 35.0,
            'abilitySize': 25.0,
            'useNeutralTeamColors': false,
          },
        ),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(activePageLiveSyncProvider.notifier).markPageHydrated(
          strategyPublicId: 'cloud-strategy',
          pageId: page.publicId,
          snapshot: container.read(remoteEditorSnapshotProvider).requireValue!,
        );

    container.read(mapProvider.notifier).switchSide();
    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, hasLength(1));
    final entry = desired!.entries.single;
    expect(entry.key, const EntitySyncKey.pageDescriptor('page-1'));
    final op = entry.value as PagePatchOp;
    expect(op.payload, {'isAttack': false});
    expect(op.expectedPageRevision, 11);
  });

  Future<ProviderContainer> openCloudPage(
    RemotePage page,
    List<RemoteLineup> lineups,
  ) async {
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote', lineups: lineups),
    ));
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );
    return container;
  }

  Map<EntitySyncKey, StrategyOp> lineupOpsAfterTextEdit(
    ProviderContainer container,
    RemotePage page,
  ) {
    container.read(textProvider).single.position = const Offset(50, 60);
    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );
    expect(desired, isNotNull);
    expect(
      desired![EntitySyncKey.element(page.publicId, 'text-page-1')]?.kind,
      StrategyOpKind.patch,
    );
    return {
      for (final entry in desired.entries)
        if (entry.key.kind == EntitySyncKeyKind.lineup) entry.key: entry.value,
    };
  }

  test('remote lineup survives hydration and an unrelated outbound diff',
      () async {
    final page = _page('page-1', 0);
    final container =
        await openCloudPage(page, [_lineup(page.publicId, 'lineup-1')]);

    final lineUps = container.read(lineUpProvider);
    expect(lineUps.origins.single.id, 'lineup-1');
    expect(lineUps.landings.single.id, 'landing-lineup-1');
    expect(lineUps.links.single.id, 'link-lineup-1');

    expect(lineupOpsAfterTextEdit(container, page), isEmpty);
    await _settle();
  });

  test(
      'copies of a shared spot that disagree are drawn apart, and opening '
      'the page writes nothing', () async {
    final page = _page('page-1', 0);
    // A change to the shared origin reached link-1 but not link-2, and one
    // to the shared landing reached link-3 but not link-2.
    final rows = [
      _lineupRow(page.publicId, 'link-1',
          origin: _originJson('origin', const Offset(100, 100)),
          landing: _landingJson('landing-1'),
          revision: 1),
      _lineupRow(page.publicId, 'link-2',
          origin: _originJson('origin', const Offset(200, 200)),
          landing: _landingJson('landing', const Offset(220, 220)),
          revision: 9,
          sortIndex: 1),
      _lineupRow(page.publicId, 'link-3',
          origin: _originJson('origin-3'),
          landing: _landingJson('landing', const Offset(330, 330)),
          revision: 2,
          sortIndex: 2),
    ];
    final container = await openCloudPage(page, rows);

    // One spot per value: the value of the smallest lineup id carrying the
    // spot keeps its id, the other is drawn under an alias. Each lineup is
    // attached to its own copy, its marker following the alias.
    final lineUps = container.read(lineUpProvider);
    expect(lineUps.origins.map((origin) => origin.id),
        ['origin', 'origin@link-2', 'origin-3']);
    expect(lineUps.landings.map((landing) => landing.id),
        ['landing-1', 'landing', 'landing@link-3']);
    expect([
      for (final link in lineUps.links) (link.id, link.originId, link.landingId)
    ], [
      ('link-1', 'origin', 'landing-1'),
      ('link-2', 'origin@link-2', 'landing'),
      ('link-3', 'origin-3', 'landing@link-3'),
    ]);
    expect(
        lineUps.originById('origin')!.agent.position, const Offset(100, 100));
    final aliasedOrigin = lineUps.originById('origin@link-2')!.agent;
    expect(aliasedOrigin.position, const Offset(200, 200));
    expect(aliasedOrigin.lineUpID, 'origin@link-2');
    expect(lineUps.landingById('landing')!.ability.position,
        const Offset(220, 220));
    final aliasedLanding = lineUps.landingById('landing@link-3')!.ability;
    expect(aliasedLanding.position, const Offset(330, 330));
    expect(aliasedLanding.lineUpID, 'landing@link-3');

    // Opening the page writes no lineup, nor does an unrelated edit.
    await _settle();
    Map<EntitySyncKey, StrategyOp> queuedLineupOps() => {
          for (final entry in container
              .read(strategyOpQueueProvider)
              .queuedByEntityKey
              .entries)
            if (entry.key.kind == EntitySyncKeyKind.lineup)
              entry.key: entry.value.pending.op,
        };
    expect(queuedLineupOps(), isEmpty);
    expect(lineupOpsAfterTextEdit(container, page), isEmpty);

    // An edit to link-2 writes its row with its own copies, under the real
    // ids, against its own revision.
    container
        .read(lineUpProvider.notifier)
        .updateLink(lineUps.linkById('link-2')!.copyWith(notes: 'jump throw'));
    await _settle();
    final link2 = EntitySyncKey.lineup(page.publicId, 'link-2');
    expect(queuedLineupOps().keys, [link2]);
    final patch = queuedLineupOps()[link2]! as LineupPatchOp;
    expect(patch.expectedLineupRevision, 9);
    final data = cloudPayloadData(patch.payload);
    expect(data['notes'], 'jump throw');
    final origin = data['origin'] as Map;
    expect(origin['id'], 'origin');
    expect((origin['agent'] as Map)['lineUpID'], 'origin');
    expect((origin['agent'] as Map)['position'], {'dx': 200.0, 'dy': 200.0});
    final landing = data['landing'] as Map;
    expect(landing['id'], 'landing');
    expect((landing['ability'] as Map)['lineUpID'], 'landing');
    expect((landing['ability'] as Map)['position'], {'dx': 220.0, 'dy': 220.0});
    await _settle();
  });

  test('a Paranoia saved at the old size opens corrected and sends nothing',
      () async {
    final page = _page('page-1', 0);
    final paranoia = PlacedAbility(
      id: 'paranoia',
      data: AgentData.agents[AgentType.omen]!.abilities[1],
      position: const Offset(400, 300),
    );
    // As a 4.6.3-era client wrote it: payload version 1, the old 25 m size.
    final saved = {
      ...cloudElementPayload(
        kind: 'ability',
        data: {...paranoia.toJson(), 'elementType': 'ability'},
      ),
      'payloadVersion': 1,
    };
    // What the editor snapshot holds once the read path has upgraded it.
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: upgradeRemotePageSnapshot(
        _pageSnapshot(page, elements: [
          _textElement(page.publicId, 'text-page-1', 'remote'),
          RemoteElement(
            publicId: paranoia.id,
            strategyPublicId: 'cloud-strategy',
            pagePublicId: page.publicId,
            elementType: 'ability',
            payload: saved,
            sortIndex: 1,
            revision: 1,
            deleted: false,
          ),
        ]),
        Maps.mapNames[MapValue.ascent]!,
      ),
    ));
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    expect(
      container.read(abilityProvider).single.position,
      ParanoiaRangeMigration.migrateAbility(paranoia, MapValue.ascent).position,
    );

    container.read(textProvider).single.position = const Offset(50, 60);
    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );
    expect(
      desired!.keys,
      allOf(
        contains(EntitySyncKey.element(page.publicId, 'text-page-1')),
        isNot(contains(EntitySyncKey.element(page.publicId, 'paranoia'))),
      ),
    );
    await _settle();
  });

  group('switching side on all cloud pages', () {
    Future<(ProviderContainer, _FakeStrategyOpQueueNotifier)>
        openTwoPages() async {
      final first = _page('page-a', 0, revision: 4);
      final second = _page('page-b', 1, revision: 7);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second],
        activePage: _pageSnapshot(first),
      ));
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, queue);
    }

    bool? queuedSideOf(_FakeStrategyOpQueueNotifier queue, String pageId) {
      final op = queue.state
          .queuedByEntityKey[EntitySyncKey.pageDescriptor(pageId)]?.pending.op;
      return op is PagePatchOp ? op.payload['isAttack'] as bool? : null;
    }

    test('a second toggle supersedes the first while it is still queued',
        () async {
      final (container, queue) = await openTwoPages();
      final notifier = container.read(strategyProvider.notifier);

      await notifier.switchSide(allPages: true);
      expect(queuedSideOf(queue, 'page-b'), isFalse);

      // The server has not taken the first change yet: page B still reads
      // Attack remotely, the side this toggle asks for.
      await notifier.switchSide(allPages: true);

      expect(container.read(mapProvider).isAttack, isTrue);
      expect(queuedSideOf(queue, 'page-b'), isTrue);
      await _settle();
    });

    test('a second toggle follows a side change that is in flight', () async {
      final (container, queue) = await openTwoPages();
      final notifier = container.read(strategyProvider.notifier);
      const key = EntitySyncKey.pageDescriptor('page-b');

      await notifier.switchSide(allPages: true);
      final sent = queue.state.queuedByEntityKey[key]!.pending.op;
      queue.state = queue.state.copyWith(
        queuedByEntityKey: const <EntitySyncKey, QueuedEntityIntent>{},
      );
      queue.holdInFlight(key, sent);

      await notifier.switchSide(allPages: true);

      expect(queuedSideOf(queue, 'page-b'), isTrue);
      await _settle();
    });

    test('overlapping toggles reconcile across unpublished durable writes',
        () async {
      final first = _page('page-a', 0, revision: 4);
      final second = _page('page-b', 1, revision: 7);
      final third = _page('page-c', 2, revision: 9);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [first, second, third],
        activePage: _pageSnapshot(first),
      ));
      final queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      final notifier = container.read(strategyProvider.notifier);

      queue.writeGate = Completer<void>();
      final toDefense = notifier.switchSide(allPages: true);
      // Starts before the first toggle's writes have published anything.
      final backToAttack = notifier.switchSide(allPages: true);
      queue.writeGate!.complete();
      await Future.wait([toDefense, backToAttack]);

      expect(container.read(mapProvider).isAttack, isTrue);
      expect(queuedSideOf(queue, 'page-b'), isTrue);
      expect(queuedSideOf(queue, 'page-c'), isTrue);
      await _settle();
    });
  });

  group('lineup history through cloud sync', () {
    const placedAt = Offset(100, 100);
    late _FakeStrategyOpQueueNotifier queue;
    late _FakeServer server;
    late _ServerRepository repository;

    /// Page settings that round-trip exactly, so live sync authors nothing
    /// for them; the agent size marks which server revision is on screen.
    CloudPayload settingsFor(int contentRevision) =>
        StrategySettings(agentSize: 30 + contentRevision.toDouble()).toJson();

    /// Opens page-1 with the lineup [rows] the server holds.
    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)>
        openEmpty([List<RemoteLineup> rows = const []]) async {
      final page = _page('page-1', 0);
      server = _FakeServer(page.publicId, lineups: rows);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage:
            _pageSnapshot(page, settings: settingsFor(1), lineups: server.rows),
      ));
      queue = _FakeStrategyOpQueueNotifier();
      final container = await _cloudContainer(remote: remote, queue: queue);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, remote, page);
    }

    /// Places a lineup the way the editor does.
    LineUpLink place(ProviderContainer container) {
      final lineUps = container.read(lineUpProvider.notifier)..startFresh();
      lineUps.setDraftAgent(PlacedAgent(
        id: 'agent-x',
        type: AgentType.sova,
        position: placedAt,
      ));
      lineUps.setDraftAbility(PlacedAbility(
        id: 'ability-x',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: const Offset(300, 300),
      ));
      return lineUps.commitPlacement()!;
    }

    Map<EntitySyncKey, StrategyOp> desiredOps(
      ProviderContainer container,
      RemotePage page,
    ) {
      return container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: page.publicId,
              ) ??
          const {};
    }

    RemoteEditorSnapshot serverSnapshot(
      RemotePage page,
      List<RemoteLineup> lineups,
      int contentRevision, {
      List<RemotePage>? pages,
    }) {
      return _editorSnapshot(
        pages: pages ?? [page],
        activePage: _pageSnapshot(
          page,
          settings: settingsFor(contentRevision),
          contentRevision: contentRevision,
          lineups: lineups,
        ),
      );
    }

    Future<void> settleSync(
        ProviderContainer container, int contentRevision) async {
      // Ack reconciliation refreshes, re-syncs and rehydrates in turn.
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      expect(
        container.read(strategySettingsProvider).agentSize,
        30 + contentRevision,
        reason: 'the page rehydrated from the server',
      );
    }

    Map<EntitySyncKey, StrategyOp> queuedOps() => {
          for (final entry in queue.state.queuedByEntityKey.entries)
            entry.key: entry.value.pending.op,
        };

    /// The lineup writes in [ops].
    Map<EntitySyncKey, StrategyOp> lineupOps(
            Map<EntitySyncKey, StrategyOp> ops) =>
        {
          for (final entry in ops.entries)
            if (entry.key.kind == EntitySyncKeyKind.lineup)
              entry.key: entry.value,
        };

    /// The stored row of lineup [id] in [lineups].
    RemoteLineup rowOf(List<RemoteLineup> lineups, String id) =>
        lineups.singleWhere((row) => row.publicId == id);

    EntitySyncKey keyOf(RemotePage page, String id) =>
        EntitySyncKey.lineup(page.publicId, id);

    /// Every row the server holds reads back as the lineup it is keyed by.
    void expectEveryRowDrawn(List<RemoteLineup> lineups) {
      expect(
        lineUpGraphFromRemoteLineups(lineups).links.map((link) => link.id),
        [for (final row in lineups) row.publicId],
      );
    }

    /// The server answers [sent]; the session's refresh after the answers
    /// reads the server as it then is, at [contentRevision]. [teammate]
    /// edits every live row's lineup data in the same round, as a teammate's
    /// change landing alongside ours would. One queue update then takes the
    /// answers (which also marks the page saved once nothing is left).
    void send(
      _FakeRemoteEditorNotifier remote,
      RemotePage page,
      Map<EntitySyncKey, StrategyOp> sent, {
      required int contentRevision,
      void Function(Map<String, dynamic> data)? teammate,
    }) {
      final acks = server.applyBatch(sent.values);
      if (teammate != null) {
        for (final row in server.liveRows) {
          server.teammateEdit(row.publicId, teammate);
        }
      }
      expectEveryRowDrawn(server.liveRows);
      remote.initialSnapshot =
          serverSnapshot(page, server.rows, contentRevision);
      queue.answer(sent, acks);
    }

    /// The edits' scheduled sync queues ops; the server answers all of them
    /// ([send]), and the session reconciles the answers, refreshes from the
    /// server and rehydrates, as in production. Returns the live rows the
    /// server holds.
    Future<List<RemoteLineup>> land(
      ProviderContainer container,
      _FakeRemoteEditorNotifier remote,
      RemotePage page, {
      required int contentRevision,
      void Function(Map<String, dynamic> data)? teammate,
    }) async {
      await _settle();
      send(remote, page, queuedOps(),
          contentRevision: contentRevision, teammate: teammate);
      await settleSync(container, contentRevision);
      return server.liveRows;
    }

    /// Every lineup write is one whole lineup row, keyed by its link.
    void expectLineupRows(Map<EntitySyncKey, StrategyOp> ops) {
      for (final op in ops.values) {
        final payload = switch (op) {
          LineupAddOp(:final payload) => payload,
          LineupPatchOp(:final payload) => payload,
          _ => null,
        };
        if (payload == null) continue;
        expect(payload['kind'], cloudLineupPayloadKind, reason: '$op');
        expect(cloudPayloadData(payload)['id'], op.entityPublicId,
            reason: '$op');
      }
    }

    test('undoing a details edit made before the first hydration', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      container
          .read(lineUpProvider.notifier)
          .updateLink(link.copyWith(notes: 'jump throw'));
      await land(container, remote, page, contentRevision: 2);

      container.read(actionProvider.notifier).undoAction();

      final lineUps = container.read(lineUpProvider);
      expect(lineUps.links.single.notes, '');
      expect(lineUps.landingById(lineUps.links.single.landingId), isNotNull);
      expect(lineUps.landings, hasLength(1));
      final afterUndo = desiredOps(container, page);
      expectLineupRows(afterUndo);
      expect(afterUndo.values.whereType<LineupDeleteOp>(), isEmpty);
      expect(afterUndo.values.whereType<LineupPatchOp>(), hasLength(1));
      expect(afterUndo.keys.single, keyOf(page, link.id));
      await _settle();
    });

    test('a landing keeps its id through sync and hydration', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      container
          .read(lineUpProvider.notifier)
          .updateLandingPosition(link.landingId, const Offset(320, 340));
      await land(container, remote, page, contentRevision: 2);

      expect(container.read(lineUpProvider).landings.single.id, link.landingId);

      // The pre-hydration landing move still undoes, onto the same landing.
      container.read(actionProvider.notifier).undoAction();
      expect(
        container.read(lineUpProvider).landings.single.ability.position,
        const Offset(300, 300),
      );
      // Undoing the placement removes the whole lineup, leaving no node.
      container.read(actionProvider.notifier).undoAction();
      final empty = container.read(lineUpProvider);
      expect(empty.links, isEmpty);
      expect(empty.origins, isEmpty);
      expect(empty.landings, isEmpty);
      await _settle();
    });

    test('undoing a move keeps a teammate weapon on the same origin', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      await land(container, remote, page, contentRevision: 2);
      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition(link.originId, const Offset(500, 500));
      await land(container, remote, page, contentRevision: 3);

      // Then a teammate arms the same origin.
      server.teammateEdit(link.id, (data) {
        final origin = data['origin'] as Map;
        (origin['agent'] as Map)['weapon'] = 'vandal';
      });
      remote.setSnapshot(serverSnapshot(page, server.rows, 4));
      await settleSync(container, 4);
      expect(
        container.read(lineUpProvider).originById(link.originId)!.agent.weapon,
        WeaponType.vandal,
      );

      container.read(actionProvider.notifier).undoAction();

      final origin = container.read(lineUpProvider).originById(link.originId)!;
      expect(origin.agent.position, placedAt);
      expect(origin.agent.weapon, WeaponType.vandal);
      final patch =
          desiredOps(container, page).values.whereType<LineupPatchOp>().single;
      final sent = cloudPayloadData(patch.payload)['origin'] as Map;
      expect((sent['agent'] as Map)['weapon'], 'vandal');
      await _settle();
    });

    test('an edit before a deletion stays undoable after the deletion lands',
        () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      await land(container, remote, page, contentRevision: 2);
      final lineUps = container.read(lineUpProvider.notifier);
      const moved = Offset(500, 500);

      lineUps.updateOriginAgentPosition(link.originId, moved);
      lineUps.deleteOrigin(link.originId);
      final after = await land(container, remote, page, contentRevision: 3);
      expect(after, isEmpty);
      // The server keeps the deleted lineup as a tombstone.
      expect(server.row(link.id).deleted, isTrue);

      final history = container.read(actionProvider.notifier);
      Offset? originPosition() => container
          .read(lineUpProvider)
          .originById(link.originId)
          ?.agent
          .position;

      history.undoAction();
      expect(originPosition(), moved);
      history.undoAction();
      expect(originPosition(), placedAt);
      history.redoAction();
      expect(originPosition(), moved);
      history.redoAction();
      expect(originPosition(), isNull);
      await _settle();
    });

    /// Places lineup A, then B from a second origin into A's landing, each
    /// link named, the way the editor does.
    (LineUpLink, LineUpLink) placeFanIn(ProviderContainer container) {
      final a = place(container);
      final lineUps = container.read(lineUpProvider.notifier)
        ..updateLink(a.copyWith(name: 'From heaven'))
        ..startToLanding(a.landingId);
      lineUps.setDraftAgent(PlacedAgent(
        id: 'agent-y',
        type: AgentType.sova,
        position: const Offset(150, 150),
      ));
      final b = lineUps.commitPlacement(name: 'From mid')!;
      expect(b.landingId, a.landingId, reason: 'B fans in to A\'s landing');
      return (container.read(lineUpProvider).linkById(a.id)!, b);
    }

    /// Places lineup A, then B from A's origin to a second landing, each
    /// link named, the way the editor does.
    (LineUpLink, LineUpLink) placeFanOut(ProviderContainer container) {
      final a = place(container);
      final lineUps = container.read(lineUpProvider.notifier)
        ..updateLink(a.copyWith(name: 'Short'))
        ..startFromOrigin(a.originId);
      lineUps.setDraftAbility(PlacedAbility(
        id: 'ability-y',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: const Offset(450, 450),
      ));
      final b = lineUps.commitPlacement(name: 'Long')!;
      expect(b.originId, a.originId, reason: 'B fans out from A\'s origin');
      return (container.read(lineUpProvider).linkById(a.id)!, b);
    }

    List<(String, String, String, String)> linkShape(LineUpState state) => [
          for (final link in state.links)
            (link.id, link.originId, link.landingId, link.name),
        ];

    /// The ids of the spots [lineups]' rows carry, by the lineup carrying
    /// them.
    Map<String, (String, String)> spotsOf(List<RemoteLineup> lineups) => {
          for (final row in lineups)
            row.publicId: (
              (cloudPayloadData(row.payload)['origin'] as Map)['id'] as String,
              (cloudPayloadData(row.payload)['landing'] as Map)['id'] as String,
            ),
        };

    test('a fan-in lineup keeps its shared landing, ids and names', () async {
      final (container, remote, page) = await openEmpty();
      final (a, b) = placeFanIn(container);
      final before = container.read(lineUpProvider);
      final originIds = before.origins.map((origin) => origin.id).toList();

      final lineups = await land(container, remote, page, contentRevision: 2);

      // One row per lineup, each carrying its own copy of the landing.
      expect(spotsOf(lineups), {
        a.id: (a.originId, a.landingId),
        b.id: (b.originId, a.landingId),
      });

      // Hydration draws the shared landing once.
      final hydrated = container.read(lineUpProvider);
      expect(hydrated.origins.map((origin) => origin.id), originIds);
      expect(hydrated.landings.single.id, a.landingId);
      expect(linkShape(hydrated), [
        (a.id, a.originId, a.landingId, 'From heaven'),
        (b.id, b.originId, a.landingId, 'From mid'),
      ]);
      expect(desiredOps(container, page), isEmpty);
      await _settle();
    });

    test('a fan-out lineup keeps its shared origin, ids and names', () async {
      final (container, remote, page) = await openEmpty();
      final (a, b) = placeFanOut(container);
      final landingIds = container
          .read(lineUpProvider)
          .landings
          .map((landing) => landing.id)
          .toList();

      final lineups = await land(container, remote, page, contentRevision: 2);

      expect(spotsOf(lineups), {
        a.id: (a.originId, a.landingId),
        b.id: (a.originId, b.landingId),
      });

      final hydrated = container.read(lineUpProvider);
      expect(hydrated.origins.single.id, a.originId);
      expect(hydrated.origins.single.agent.position, placedAt);
      expect(hydrated.landings.map((landing) => landing.id), landingIds);
      expect(linkShape(hydrated), [
        (a.id, a.originId, a.landingId, 'Short'),
        (b.id, a.originId, b.landingId, 'Long'),
      ]);
      expect(desiredOps(container, page), isEmpty);
      await _settle();
    });

    test('moving a shared spot patches every lineup on it and nothing else',
        () async {
      final (container, remote, page) = await openEmpty();
      final (a, b) = placeFanIn(container);
      final other = place(container);
      var lineups = await land(container, remote, page, contentRevision: 2);
      // A's row moves on to revision 2; B's and the other's stay at 1.
      container.read(lineUpProvider.notifier).updateLink(
          container.read(lineUpProvider).linkById(a.id)!.copyWith(notes: 'x'));
      lineups = await land(container, remote, page, contentRevision: 3);
      expect(
        {for (final row in lineups) row.publicId: row.revision},
        {a.id: 2, b.id: 1, other.id: 1},
      );

      const moved = Offset(320, 340);
      container
          .read(lineUpProvider.notifier)
          .updateLandingPosition(a.landingId, moved);

      // One patch per lineup on the landing, each checked against its own
      // row's revision, each carrying the moved landing.
      final ops = desiredOps(container, page);
      expectLineupRows(ops);
      expect(ops.keys.toSet(), {keyOf(page, a.id), keyOf(page, b.id)});
      final patches = ops.values.cast<LineupPatchOp>();
      expect(
        {
          for (final op in patches) op.lineupPublicId: op.expectedLineupRevision
        },
        {a.id: 2, b.id: 1},
      );
      for (final op in patches) {
        final landing = cloudPayloadData(op.payload)['landing'] as Map;
        expect((landing['ability'] as Map)['position'],
            {'dx': moved.dx, 'dy': moved.dy});
      }

      lineups = await land(container, remote, page, contentRevision: 4);
      expect(
        {for (final row in lineups) row.publicId: row.revision},
        {a.id: 3, b.id: 2, other.id: 1},
      );
      expect(
        {for (final row in lineups) row.publicId: _endsOf(row).landingAt},
        {a.id: moved, b.id: moved, other.id: const Offset(300, 300)},
      );
      final hydrated = container.read(lineUpProvider);
      expect(hydrated.landingById(a.landingId)!.ability.position, moved);
      expect(hydrated.landings, hasLength(2));
      expect(desiredOps(container, page), isEmpty);
      await _settle();
    });

    test('undoing a deletion rejoins the surviving shared landing', () async {
      final (container, remote, page) = await openEmpty();
      final (a, b) = placeFanIn(container);
      var lineups = await land(container, remote, page, contentRevision: 2);
      container.read(lineUpProvider.notifier).deleteOrigin(a.originId);
      lineups = await land(container, remote, page, contentRevision: 3);
      expect(spotsOf(lineups), {b.id: (b.originId, a.landingId)});

      container.read(actionProvider.notifier).undoAction();

      final restored = container.read(lineUpProvider);
      expect(restored.landings.single.id, a.landingId);
      expect(linkShape(restored), [
        (b.id, b.originId, a.landingId, 'From mid'),
        (a.id, a.originId, a.landingId, 'From heaven'),
      ]);
      final ops = desiredOps(container, page);
      expectLineupRows(ops);
      expect(ops.keys, [keyOf(page, a.id)]);
      // An add over the tombstone the delete left, expecting its revision.
      expect(server.row(a.id).deleted, isTrue);
      expect(
        (ops.values.single as LineupAddOp).expectedLineupRevision,
        server.row(a.id).revision,
      );
      lineups = await land(container, remote, page, contentRevision: 4);
      expect(spotsOf(lineups), {
        b.id: (b.originId, a.landingId),
        a.id: (a.originId, a.landingId),
      });
      expect(server.row(a.id).revision, 3);
      expect(linkShape(container.read(lineUpProvider)), hasLength(2));
      await _settle();
    });

    test(
        'deleting a lineup takes the spots nothing else uses and keeps a '
        'shared one', () async {
      final (container, remote, page) = await openEmpty();
      final (a, b) = placeFanIn(container);
      var lineups = await land(container, remote, page, contentRevision: 2);

      container.read(lineUpProvider.notifier).deleteLink(a.id);

      // A's origin went with it; the landing B still uses stayed.
      var graph = container.read(lineUpProvider).graph;
      expect(graph.origins.map((origin) => origin.id), [b.originId]);
      expect(graph.landings.map((landing) => landing.id), [a.landingId]);
      // Only A's row is deleted; B's row, landing copy and all, is left be.
      final ops = desiredOps(container, page);
      expect(ops.keys, [keyOf(page, a.id)]);
      expect(ops.values.single, isA<LineupDeleteOp>());
      lineups = await land(container, remote, page, contentRevision: 3);
      expect(spotsOf(lineups), {b.id: (b.originId, a.landingId)});
      graph = container.read(lineUpProvider).graph;
      expect(graph.links.map((link) => link.id), [b.id]);
      expect(graph.landings.map((landing) => landing.id), [a.landingId]);

      // Deleting the last lineup on the landing takes the landing too.
      container.read(lineUpProvider.notifier).deleteLink(b.id);
      graph = container.read(lineUpProvider).graph;
      expect(graph.origins, isEmpty);
      expect(graph.landings, isEmpty);
      lineups = await land(container, remote, page, contentRevision: 4);
      expect(lineups, isEmpty);
      expect(container.read(lineUpProvider).graph.landings, isEmpty);
      await _settle();
    });

    test('a teammate editing the other link of a fan-in keeps both edits',
        () async {
      final (container, remote, page) = await openEmpty();
      final (a, b) = placeFanIn(container);
      await land(container, remote, page, contentRevision: 2);
      container
          .read(lineUpProvider.notifier)
          .updateLink(container.read(lineUpProvider).linkById(a.id)!.copyWith(
                notes: 'jump throw',
              ));
      await _settle();
      // Only A's row is written, checked against A's own revision, so a
      // teammate's write to B's row cannot conflict with it.
      final mine = queuedOps();
      expect(
        mine.keys.where((key) => key.kind == EntitySyncKeyKind.lineup),
        [keyOf(page, a.id)],
      );
      expect(
        (mine[keyOf(page, a.id)]! as LineupPatchOp).expectedLineupRevision,
        1,
      );

      await land(
        container,
        remote,
        page,
        contentRevision: 3,
        teammate: (data) {
          if (data['id'] == b.id) data['notes'] = 'teammate notes';
        },
      );

      final hydrated = container.read(lineUpProvider);
      expect(hydrated.linkById(a.id)!.notes, 'jump throw');
      expect(hydrated.linkById(b.id)!.notes, 'teammate notes');
      expect(hydrated.landings.single.id, a.landingId);
      expect(desiredOps(container, page), isEmpty);
      expect(queue.state.attentionByEntityKey, isEmpty);
      await _settle();
    });

    test('a stale edit to a lineup a teammate changed conflicts', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      await land(container, remote, page, contentRevision: 2);
      container
          .read(lineUpProvider.notifier)
          .updateLink(link.copyWith(notes: 'mine'));
      await _settle();
      final key = keyOf(page, link.id);
      final mine = queuedOps()[key]! as LineupPatchOp;
      expect(mine.expectedLineupRevision, 1);

      // A teammate's notes edit to the same lineup lands first.
      server.teammateEdit(link.id, (data) => data['notes'] = 'theirs');
      remote.setSnapshot(serverSnapshot(page, server.rows, 3));
      await _settle();
      // Still checked against the version the user saw: never re-based onto
      // theirs, which would overwrite it in silence.
      expect(
        (queuedOps()[key]! as LineupPatchOp).expectedLineupRevision,
        1,
      );

      // The server refuses it; the user sees their work and a conflict.
      send(remote, page, queuedOps(), contentRevision: 3);
      await _settle();
      expect(
        queue.state.lastAckBatch
            .singleWhere((acked) => acked.entityKey == key)
            .ack,
        isA<RejectedOpAck>().having((ack) => ack.rejectionReason, 'reason',
            OpRejectionReason.revisionMismatch),
      );
      expect(cloudPayloadData(server.row(link.id).payload)['notes'], 'theirs');
      expect(container.read(lineUpProvider).links.single.notes, 'mine');
      expect(queue.state.needsAttention, isTrue);
      expect(queue.state.attentionByEntityKey.keys, [key]);
      expect(container.read(strategyConflictProvider), hasLength(1));

      // Using theirs shows the teammate's notes and sends nothing.
      final resolved = await container
          .read(strategyPageSessionProvider.notifier)
          .useCloudVersionsForRejected();
      await _settle();
      expect(resolved, isTrue);
      expect(container.read(lineUpProvider).links.single.notes, 'theirs');
      expect(queue.state.attentionByEntityKey, isEmpty);
      expect(
        queuedOps().keys.where((key) => key.kind == EntitySyncKeyKind.lineup),
        isEmpty,
      );
    });

    test(
        'deleting a spot while a teammate adds a lineup to it keeps '
        'theirs whole', () async {
      final (container, remote, page) = await openEmpty();
      final first = place(container);
      final landed = await land(container, remote, page, contentRevision: 2);

      // A teammate's lineup from the same origin, carrying their own copy
      // of it, lands; this canvas has not drawn it yet.
      server.teammateAdd(RemoteLineup(
        publicId: 'their-link',
        strategyPublicId: 'cloud-strategy',
        pagePublicId: page.publicId,
        payload: cloudLineupPayload({
          ...cloudPayloadData(rowOf(landed, first.id).payload),
          'id': 'their-link',
          'name': 'Theirs',
          'landing': _landingJson('their-landing', const Offset(80, 80)),
        }),
        sortIndex: 10,
        revision: 1,
        deleted: false,
      ));

      // The user deletes the origin, which takes their only lineup on it.
      container.read(lineUpProvider.notifier).deleteOrigin(first.originId);
      await _settle();
      final sent = queuedOps();
      expect(lineupOps(sent).keys, [keyOf(page, first.id)]);
      expect(lineupOps(sent).values.single, isA<LineupDeleteOp>());

      // The server deletes the user's row; the teammate's row is untouched.
      send(remote, page, sent, contentRevision: 3);
      await settleSync(container, 3);
      expect(server.row(first.id).deleted, isTrue);
      expect(server.row('their-link').revision, 1);

      // Their lineup is drawn whole, on the origin from its own row.
      final graph = container.read(lineUpProvider).graph;
      expect(graph.links.map((link) => link.id), ['their-link']);
      expect(graph.origins.map((origin) => origin.id), [first.originId]);
      expect(graph.origins.single.agent.position, placedAt);
      expect(graph.landings.map((landing) => landing.id), ['their-landing']);
      expect(queue.state.attentionByEntityKey, isEmpty);
      expect(desiredOps(container, page), isEmpty);
      await _settle();
    });

    test('a lineup placed from an origin a teammate deleted saves whole',
        () async {
      final (container, remote, page) = await openEmpty();
      final first = place(container);
      await land(container, remote, page, contentRevision: 2);

      // The user starts a new lineup from the landed origin...
      final lineUps = container.read(lineUpProvider.notifier)
        ..startFromOrigin(first.originId);
      lineUps.setDraftAbility(PlacedAbility(
        id: 'ability-y',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: const Offset(500, 500),
      ));
      // ...while a teammate deletes that lineup, origin included.
      server.teammateDelete(first.id);
      remote.setSnapshot(serverSnapshot(page, server.rows, 3));
      await _settle();
      // The teammate's delete stands: the user never re-sends it.
      expect(
          desiredOps(container, page), isNot(contains(keyOf(page, first.id))));

      final second = lineUps.commitPlacement()!;
      await _settle();

      // The new lineup's row carries its own copy of the origin, so it
      // saves whole without the deleted lineup.
      final queued = lineupOps(queuedOps());
      expect(queued.keys, [keyOf(page, second.id)]);
      final add = queued.values.single as LineupAddOp;
      expect(
        (cloudPayloadData(add.payload)['origin'] as Map)['id'],
        first.originId,
      );

      // The server holds the new lineup whole, and it loads back.
      final stored = await land(container, remote, page, contentRevision: 4);
      expect(stored.map((row) => row.publicId), [second.id]);
      expect(server.row(first.id).deleted, isTrue);
      final hydrated = container.read(lineUpProvider).graph;
      expect(hydrated.links.map((link) => link.id), [second.id]);
      expect(hydrated.origins.map((origin) => origin.id), [first.originId]);
      await _settle();
    });

    test('each lineup action undoes after hydration, one write at a time',
        () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      var contentRevision = 2;
      var lineups = await land(container, remote, page,
          contentRevision: contentRevision++);
      Future<void> landNext() async {
        lineups = await land(container, remote, page,
            contentRevision: contentRevision++);
      }

      final lineUps = container.read(lineUpProvider.notifier);
      LineUpState state() => container.read(lineUpProvider);
      lineUps.updateLink(state().linkById(link.id)!.copyWith(name: 'Heaven'));
      await landNext();
      lineUps.updateOriginAgentPosition(link.originId, const Offset(500, 500));
      await landNext();
      lineUps.updateLandingPosition(link.landingId, const Offset(320, 340));
      await landNext();
      lineUps.updateLandingAbilityVisualState(
        landingId: link.landingId,
        visualState: state()
            .landingById(link.landingId)!
            .ability
            .visualState
            .copyWith(showRangeOutline: false),
      );
      await landNext();
      lineUps.setOriginWeapon(link.originId, WeaponType.vandal);
      await landNext();
      expect(state().linkById(link.id)!.name, 'Heaven');

      final key = keyOf(page, link.id);
      final history = container.read(actionProvider.notifier);
      // Undoes one step and lands it; returns the one write it made.
      Future<StrategyOp> undoAndLand() async {
        history.undoAction();
        final ops = desiredOps(container, page);
        expectLineupRows(ops);
        expect(ops.keys, [key]);
        await landNext();
        return ops.values.single;
      }

      expect(await undoAndLand(), isA<LineupPatchOp>());
      expect(state().originById(link.originId)!.agent.weapon,
          isNot(WeaponType.vandal));
      expect(await undoAndLand(), isA<LineupPatchOp>());
      expect(
        state()
            .landingById(link.landingId)!
            .ability
            .visualState
            .showRangeOutline,
        isTrue,
      );
      expect(await undoAndLand(), isA<LineupPatchOp>());
      expect(state().landingById(link.landingId)!.ability.position,
          const Offset(300, 300));
      expect(await undoAndLand(), isA<LineupPatchOp>());
      expect(state().originById(link.originId)!.agent.position, placedAt);
      expect(await undoAndLand(), isA<LineupPatchOp>());
      expect(state().linkById(link.id)!.name, '');
      expect(await undoAndLand(), isA<LineupDeleteOp>());
      expect(state().links, isEmpty);
      expect(lineups, isEmpty);

      history.redoAction();
      expect(state().links.single.id, link.id);
      expect(state().landings.single.id, link.landingId);
      expect(state().origins.single.id, link.originId);
      await _settle();
    });

    test('undoing a notes edit keeps an image a teammate added', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      await land(container, remote, page, contentRevision: 2);
      container
          .read(lineUpProvider.notifier)
          .updateLink(link.copyWith(notes: 'jump throw'));
      await land(
        container,
        remote,
        page,
        contentRevision: 3,
        teammate: (data) {
          data['images'] = [
            {'id': 'teammate-image', 'fileExtension': '.png'},
          ];
        },
      );
      expect(
        container.read(lineUpProvider).links.single.images.map((i) => i.id),
        ['teammate-image'],
      );

      container.read(actionProvider.notifier).undoAction();

      final restored = container.read(lineUpProvider).links.single;
      expect(restored.notes, '');
      expect(restored.images.map((image) => image.id), ['teammate-image']);
      final patch =
          desiredOps(container, page).values.whereType<LineupPatchOp>().single;
      final item = cloudPayloadData(patch.payload);
      expect(patch.lineupPublicId, link.id);
      expect(item['notes'], '');
      expect(
        (item['images'] as List).map((image) => (image as Map)['id']),
        ['teammate-image'],
      );
      await _settle();
    });

    List<String> imageIds(ProviderContainer container) => container
        .read(lineUpProvider)
        .links
        .single
        .images
        .map((image) => image.id)
        .toList();

    List<SimpleImageData> images(List<String> ids) => [
          for (final id in ids) SimpleImageData(id: id, fileExtension: '.png'),
        ];

    test('undo and redo of image removals keep the image order', () async {
      final (container, remote, page) = await openEmpty();
      final placed = place(container);
      final lineUps = container.read(lineUpProvider.notifier);
      lineUps.updateLink(placed.copyWith(images: images(['a', 'b', 'c', 'd'])));
      await land(container, remote, page, contentRevision: 2);
      // Remove the first image, then two from the middle.
      lineUps.updateLink(container
          .read(lineUpProvider)
          .links
          .single
          .copyWith(images: images(['b', 'c', 'd'])));
      lineUps.updateLink(container
          .read(lineUpProvider)
          .links
          .single
          .copyWith(images: images(['d'])));
      await land(container, remote, page, contentRevision: 3);
      final history = container.read(actionProvider.notifier);

      history.undoAction();
      expect(imageIds(container), ['b', 'c', 'd']);
      history.undoAction();
      expect(imageIds(container), ['a', 'b', 'c', 'd']);
      final patch =
          desiredOps(container, page).values.whereType<LineupPatchOp>().single;
      expect(
        (cloudPayloadData(patch.payload)['images'] as List)
            .map((image) => (image as Map)['id']),
        ['a', 'b', 'c', 'd'],
      );
      history.redoAction();
      expect(imageIds(container), ['b', 'c', 'd']);
      history.redoAction();
      expect(imageIds(container), ['d']);
      history.undoAction();
      history.undoAction();
      expect(imageIds(container), ['a', 'b', 'c', 'd']);
      await _settle();
    });

    test('undoing an image removal keeps an image a teammate added between',
        () async {
      final (container, remote, page) = await openEmpty();
      final placed = place(container);
      final lineUps = container.read(lineUpProvider.notifier);
      lineUps.updateLink(placed.copyWith(images: images(['a', 'b', 'c'])));
      await land(container, remote, page, contentRevision: 2);
      lineUps.updateLink(container
          .read(lineUpProvider)
          .links
          .single
          .copyWith(images: images(['a', 'c'])));
      // Our removal of b lands, and a teammate adds x right after a.
      await land(
        container,
        remote,
        page,
        contentRevision: 3,
        teammate: (data) {
          (data['images'] as List)
              .insert(1, {'id': 'x', 'fileExtension': '.png'});
        },
      );
      expect(imageIds(container), ['a', 'x', 'c']);
      final history = container.read(actionProvider.notifier);

      history.undoAction();
      expect(imageIds(container), ['a', 'x', 'b', 'c']);
      history.redoAction();
      expect(imageIds(container), ['a', 'x', 'c']);
      history.undoAction();
      expect(imageIds(container), ['a', 'x', 'b', 'c']);
      await _settle();
    });

    test('undoing a visibility toggle keeps a teammate toggle', () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      await land(container, remote, page, contentRevision: 2);
      final landing = container.read(lineUpProvider).landings.single;
      container.read(lineUpProvider.notifier).updateLandingAbilityVisualState(
            landingId: link.landingId,
            visualState:
                landing.ability.visualState.copyWith(showRangeOutline: false),
          );
      await land(
        container,
        remote,
        page,
        contentRevision: 3,
        teammate: (data) {
          final landing = data['landing'] as Map;
          final ability = landing['ability'] as Map;
          (ability['visualState'] as Map)['showRangeFill'] = false;
        },
      );

      container.read(actionProvider.notifier).undoAction();

      final visual = container
          .read(lineUpProvider)
          .landingById(link.landingId)!
          .ability
          .visualState;
      expect(visual.showRangeOutline, isTrue);
      expect(visual.showRangeFill, isFalse);
      await _settle();
    });

    test('an ack refresh that already holds a teammate change shows it',
        () async {
      final (container, remote, page) = await openEmpty();
      final link = place(container);
      await land(container, remote, page, contentRevision: 2);
      const moved = Offset(500, 500);
      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition(link.originId, moved);
      // Our move lands and, in the same server state, a teammate arms it.
      await land(
        container,
        remote,
        page,
        contentRevision: 3,
        teammate: (data) {
          final origin = data['origin'] as Map;
          (origin['agent'] as Map)['weapon'] = 'vandal';
        },
      );

      final origin = container.read(lineUpProvider).originById(link.originId)!;
      expect(origin.agent.position, moved);
      expect(origin.agent.weapon, WeaponType.vandal);
      final ops = desiredOps(container, page);
      expect(ops[keyOf(page, link.id)], isNull);
      await _settle();
    });

    test('an ack while another page is active does not revive the old lineup',
        () async {
      final first = _page('page-1', 0);
      final second = _page('page-2', 1);
      final secondSnapshot = _pageSnapshot(second, settings: settingsFor(9));
      final remote = _FakeRemoteEditorNotifier(
        _editorSnapshot(
          pages: [first, second],
          activePage: _pageSnapshot(first, settings: settingsFor(1)),
        ),
        pageCatalog: {
          first.publicId: _pageSnapshot(first, settings: settingsFor(1)),
          second.publicId: secondSnapshot,
        },
      );
      queue = _FakeStrategyOpQueueNotifier();
      server = _FakeServer(first.publicId);
      final container = await _cloudContainer(remote: remote, queue: queue);
      final session = container.read(strategyPageSessionProvider.notifier);
      await session.initializeForStrategy(
        strategyId: 'cloud-strategy',
        source: StrategySource.cloud,
        selectFirstPageIfNeeded: true,
      );
      final link = place(container);
      await _settle();
      var ops = queuedOps();
      var acks = server.applyBatch(ops.values);
      remote.initialSnapshot =
          serverSnapshot(first, server.rows, 2, pages: [first, second]);
      remote.pageCatalog[first.publicId] = remote.initialSnapshot.activePage!;
      queue.answer(ops, acks);
      await settleSync(container, 2);

      const moved = Offset(500, 500);
      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition(link.originId, moved);
      await session.setActivePage(second.publicId);
      await _settle();
      expect(container.read(strategySettingsProvider).agentSize, 39);

      // Page 1's move lands with a teammate's weapon change while page 2 is
      // on screen.
      ops = queuedOps();
      expect(ops.keys.where((key) => key.pageId == first.publicId), isNotEmpty);
      acks = server.applyBatch(ops.values);
      server.teammateEdit(link.id, (data) {
        final origin = data['origin'] as Map;
        (origin['agent'] as Map)['weapon'] = 'vandal';
      });
      remote.pageCatalog[first.publicId] = _pageSnapshot(
        first,
        settings: settingsFor(3),
        contentRevision: 3,
        lineups: server.rows,
      );
      remote.initialSnapshot = _editorSnapshot(
        pages: [first, second],
        activePage: secondSnapshot,
      );
      queue.answer(ops, acks);
      await settleSync(container, 9);

      await session.setActivePage(first.publicId);
      await settleSync(container, 3);

      final origin = container.read(lineUpProvider).originById(link.originId)!;
      expect(origin.agent.position, moved);
      expect(origin.agent.weapon, WeaponType.vandal);
      expect(
        desiredOps(container, first)[keyOf(first, link.id)],
        isNull,
      );
      await _settle();
    });

    /// Places lineups A and B from one origin, then C from it too, the way
    /// the editor does.
    List<LineUpLink> placeFanOutOfThree(ProviderContainer container) {
      final (a, b) = placeFanOut(container);
      final lineUps = container.read(lineUpProvider.notifier)
        ..startFromOrigin(a.originId);
      lineUps.setDraftAbility(PlacedAbility(
        id: 'ability-z',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: const Offset(600, 450),
      ));
      final c = lineUps.commitPlacement(name: 'Deep')!;
      return [a, b, c];
    }

    test(
        'a shared spot moved on only some rows stays queued for the rest '
        'until it lands', () async {
      final (container, remote, page) = await openEmpty();
      final [a, b, c] = placeFanOutOfThree(container);
      await land(container, remote, page, contentRevision: 2);
      expect(
        {for (final row in server.liveRows) row.publicId: row.revision},
        {a.id: 1, b.id: 1, c.id: 1},
      );

      const moved = Offset(500, 500);
      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition(a.originId, moved);
      await _settle();
      final sent = lineupOps(queuedOps());
      final cKey = keyOf(page, c.id);
      expect(sent.keys.toSet(), {keyOf(page, a.id), keyOf(page, b.id), cKey});

      // The server takes A's and B's patches; C's send fails, so it waits in
      // the queue while the session refreshes from the server.
      send(remote, page, {...sent}..remove(cKey), contentRevision: 3);
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      // The rows disagree now: C's still holds the old origin.
      expect(
        {
          for (final row in server.liveRows) row.publicId: _endsOf(row).originAt
        },
        {a.id: moved, b.id: moved, c.id: placedAt},
      );

      // C's patch is not taken as done by the refresh: it is still queued,
      // the same op, until C's row holds the moved origin.
      expect(lineupOps(queuedOps()).keys, [cKey]);
      expect(queuedOps()[cKey]!.opId, sent[cKey]!.opId);
      // Meanwhile the user's canvas keeps the move on all three lineups.
      final onScreen = container.read(lineUpProvider);
      expect(onScreen.origins.map((origin) => origin.id), [a.originId]);
      expect(onScreen.origins.single.agent.position, moved);

      // The user carries on, so the page syncs against that snapshot. C's
      // patch still waits, against C's revision, under the origin's id.
      container.read(lineUpProvider.notifier).updateLink(container
          .read(lineUpProvider)
          .linkById(a.id)!
          .copyWith(notes: 'next'));
      await _settle();
      final waiting = lineupOps(queuedOps());
      expect(waiting.keys.toSet(), {keyOf(page, a.id), cKey});
      final patch = waiting[cKey]! as LineupPatchOp;
      expect(patch.expectedLineupRevision, 1);
      final origin = cloudPayloadData(patch.payload)['origin'] as Map;
      expect(origin['id'], a.originId);
      expect((origin['agent'] as Map)['position'],
          {'dx': moved.dx, 'dy': moved.dy});

      // Its retry lands: every row holds the moved origin.
      await land(container, remote, page, contentRevision: 4);
      expect(
        {for (final row in server.liveRows) row.publicId: row.revision},
        {a.id: 3, b.id: 2, c.id: 2},
      );
      for (final row in server.liveRows) {
        expect(_endsOf(row).origin, a.originId, reason: row.publicId);
        expect(_endsOf(row).originAt, moved, reason: row.publicId);
      }
      // Three adds, three patches of the origin, and the notes; nothing more.
      expect(server.received, hasLength(7));
      expect(lineupOps(queuedOps()), isEmpty);
      expect(desiredOps(container, page), isEmpty);
      expect(queue.state.attentionByEntityKey, isEmpty);

      // The rows agree again, so the origin is drawn as one spot.
      final hydrated = container.read(lineUpProvider);
      expect(hydrated.origins.map((origin) => origin.id), [a.originId]);
      expect(hydrated.origins.single.agent.position, moved);
      expect(hydrated.links.map((link) => link.originId).toSet(), {a.originId});
      await _settle();
    });

    const newer = Offset(330, 330);
    const older = Offset(220, 220);

    /// Lineups A and B into one landing whose rows disagree: A's copy is at
    /// [newer], B's at [older]. B's row has the higher revision, which ranks
    /// nothing.
    List<RemoteLineup> divergedFanIn(String pageId) => [
          _lineupRow(pageId, 'link-a',
              origin: _originJson('origin-a'),
              landing: _landingJson('landing', newer),
              revision: 1),
          _lineupRow(pageId, 'link-b',
              origin: _originJson('origin-b', const Offset(60, 20)),
              landing: _landingJson('landing', older),
              revision: 7,
              sortIndex: 1),
        ];

    /// Each lineup drawn, with the spot ids it is attached to.
    List<(String, String, String)> drawnLinks(ProviderContainer container) => [
          for (final link in container.read(lineUpProvider).links)
            (link.id, link.originId, link.landingId),
        ];

    Offset? landingAt(ProviderContainer container, String id) =>
        container.read(lineUpProvider).landingById(id)?.ability.position;

    test('opening a page whose copies agree writes no lineup', () async {
      final (container, remote, page) = await openEmpty([
        _lineupRow('page-1', 'link-a',
            origin: _originJson('origin-a'),
            landing: _landingJson('landing', newer),
            revision: 3),
        _lineupRow('page-1', 'link-b',
            origin: _originJson('origin-b', const Offset(60, 20)),
            landing: _landingJson('landing', newer),
            revision: 8,
            sortIndex: 1),
      ]);
      await _settle();
      expect(container.read(lineUpProvider).landings.map((l) => l.id),
          ['landing']);
      expect(drawnLinks(container), [
        ('link-a', 'origin-a', 'landing'),
        ('link-b', 'origin-b', 'landing'),
      ]);
      expect(lineupOps(queuedOps()), isEmpty);

      // Nor does the next hydration.
      remote.setSnapshot(serverSnapshot(page, server.rows, 2));
      await settleSync(container, 2);
      expect(lineupOps(queuedOps()), isEmpty);
      expect(server.received, isEmpty);
    });

    test(
        'opening a page whose copies disagree writes nothing and draws each '
        'copy as its own spot', () async {
      final (container, remote, page) = await openEmpty([
        ...divergedFanIn('page-1'),
        _lineupRow('page-1', 'link-c',
            origin: _originJson('origin-c', const Offset(90, 20)),
            landing: _landingJson('landing', older),
            revision: 4,
            sortIndex: 2),
        _lineupRow('page-1', 'link-d',
            origin: _originJson('origin-d', const Offset(10, 90)),
            landing: _landingJson('landing-d'),
            sortIndex: 3),
      ]);
      void expectSplit() {
        // A's copy, carried by the smallest lineup id, keeps the landing's
        // id; B's and C's, which agree, share one aliased spot.
        expect(container.read(lineUpProvider).landings.map((l) => l.id),
            ['landing', 'landing@link-b', 'landing-d']);
        expect(landingAt(container, 'landing'), newer);
        expect(landingAt(container, 'landing@link-b'), older);
        expect(drawnLinks(container), [
          ('link-a', 'origin-a', 'landing'),
          ('link-b', 'origin-b', 'landing@link-b'),
          ('link-c', 'origin-c', 'landing@link-b'),
          ('link-d', 'origin-d', 'landing-d'),
        ]);
      }

      expectSplit();
      await _settle();
      expect(lineupOps(queuedOps()), isEmpty);

      // A teammate's unrelated change brings a fresh hydration: the same
      // spots are drawn, and still nothing is written.
      server.teammateEdit('link-d', (data) => data['notes'] = 'teammate');
      remote.setSnapshot(serverSnapshot(page, server.rows, 2));
      await settleSync(container, 2);
      expect(
          container.read(lineUpProvider).linkById('link-d')!.notes, 'teammate');
      expectSplit();
      expect(lineupOps(queuedOps()), isEmpty);
      expect(desiredOps(container, page), isEmpty);
      expect(server.received, isEmpty);
    });

    for (final (deleted, kept, keptAt) in [
      ('link-a', 'link-b', older),
      ('link-b', 'link-a', newer),
    ]) {
      test(
          'deleting $deleted from a landing whose copies disagree leaves '
          '$kept on its own copy, its row untouched', () async {
        final (container, remote, page) =
            await openEmpty(divergedFanIn('page-1'));
        final keptRow = server.row(kept);

        container.read(lineUpProvider.notifier).deleteLink(deleted);
        await _settle();
        // Only the deletion is written.
        final ops = lineupOps(queuedOps());
        expect(ops.keys, [keyOf(page, deleted)]);
        expect(ops.values.single, isA<LineupDeleteOp>());
        expect(drawnLinks(container).single.$1, kept);
        expect(
          landingAt(container, drawnLinks(container).single.$3),
          keptAt,
        );

        await land(container, remote, page, contentRevision: 2);
        expect(server.row(deleted).deleted, isTrue);
        expect(server.received, hasLength(1));
        // The kept lineup's row is as it was, its own copy and all.
        expect(server.row(kept).revision, keptRow.revision);
        expect(
          canonicalCloudJsonEncode(server.row(kept).payload),
          canonicalCloudJsonEncode(keptRow.payload),
        );
        // Drawn on its copy, under the landing's own id now nothing
        // disagrees with it, here and for anyone opening the page.
        expect(drawnLinks(container).single.$3, 'landing');
        expect(landingAt(container, 'landing'), keptAt);
        expect(
          lineUpGraphFromRemoteLineups(server.liveRows)
              .landings
              .single
              .ability
              .position,
          keptAt,
        );
        expect(lineupOps(queuedOps()), isEmpty);
        expect(desiredOps(container, page), isEmpty);
        await _settle();
      });
    }

    test(
        'moving one copy of a split spot patches only the rows carrying it, '
        'and once they agree the spot is drawn as one', () async {
      final (container, remote, page) = await openEmpty([
        ...divergedFanIn('page-1'),
        _lineupRow('page-1', 'link-c',
            origin: _originJson('origin-c', const Offset(90, 20)),
            landing: _landingJson('landing', older),
            revision: 4,
            sortIndex: 2),
      ]);
      const moved = Offset(500, 500);

      /// The landing [op] writes: under the real id, its marker naming it,
      /// at [moved].
      void expectMovedLanding(StrategyOp op) {
        final landing =
            cloudPayloadData((op as LineupPatchOp).payload)['landing'] as Map;
        expect(landing['id'], 'landing');
        expect((landing['ability'] as Map)['lineUpID'], 'landing');
        expect((landing['ability'] as Map)['position'],
            {'dx': moved.dx, 'dy': moved.dy});
      }

      // The aliased copy, B's and C's: only their rows, each against its
      // own revision.
      container
          .read(lineUpProvider.notifier)
          .updateLandingPosition('landing@link-b', moved);
      var ops = lineupOps(desiredOps(container, page));
      expect(
        {
          for (final op in ops.values.cast<LineupPatchOp>())
            op.lineupPublicId: op.expectedLineupRevision,
        },
        {'link-b': 7, 'link-c': 4},
      );
      ops.values.forEach(expectMovedLanding);
      await land(container, remote, page, contentRevision: 2);
      expect(
        {for (final row in server.liveRows) row.publicId: row.revision},
        {'link-a': 1, 'link-b': 8, 'link-c': 5},
      );
      // A's copy still differs, so the spot is still drawn split.
      expect(landingAt(container, 'landing'), newer);
      expect(landingAt(container, 'landing@link-b'), moved);

      // The real-id copy, A's: only A's row.
      container
          .read(lineUpProvider.notifier)
          .updateLandingPosition('landing', moved);
      ops = lineupOps(desiredOps(container, page));
      expect(ops.keys, [keyOf(page, 'link-a')]);
      expect((ops.values.single as LineupPatchOp).expectedLineupRevision, 1);
      expectMovedLanding(ops.values.single);
      await land(container, remote, page, contentRevision: 3);
      expect(
        {for (final row in server.liveRows) row.publicId: row.revision},
        {'link-a': 2, 'link-b': 8, 'link-c': 5},
      );

      // Every copy agrees: one spot again, every lineup on it.
      expect(container.read(lineUpProvider).landings.map((l) => l.id),
          ['landing']);
      expect(landingAt(container, 'landing'), moved);
      expect(
        drawnLinks(container).map((link) => link.$3).toSet(),
        {'landing'},
      );
      expect(server.received, hasLength(3));
      expect(lineupOps(queuedOps()), isEmpty);
      expect(desiredOps(container, page), isEmpty);
      await _settle();
    });

    /// Opens [page] on the real queue, its outbox kept in [store], which
    /// sends to [server] through [repository] and reads it back after every
    /// batch. A batch waits for [hold] while it is set. Returns the
    /// container and the batches sent.
    Future<(ProviderContainer, List<List<StrategyOp>>)> openOnRealQueue(
      RemotePage page, {
      DurableStrategyOutboxStore? store,
      Completer<void>? hold,
    }) async {
      RemoteEditorSnapshot read() => _editorSnapshot(
            pages: [page],
            activePage: _pageSnapshot(
              page,
              settings: settingsFor(1),
              elements: server.elements,
              lineups: server.rows,
            ),
          );
      final remote = _FakeRemoteEditorNotifier(read());
      repository = _ServerRepository(
        server,
        afterBatch: () => remote.initialSnapshot = read(),
      )..hold = hold;
      final container = ProviderContainer(overrides: [
        remoteEditorSnapshotProvider.overrideWith(() => remote),
        durableStrategyOutboxStoreProvider
            .overrideWithValue(store ?? MemoryDurableStrategyOutboxStore()),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        authProvider.overrideWith(_CloudReadyAuthProvider.new),
        convexConnectionSnapshotProvider.overrideWithValue(true),
        cloudMediaAccountIdProvider.overrideWithValue('account-a'),
        cloudMediaUploadQueueProvider
            .overrideWith(() => _RecordingMediaQueue()),
      ]);
      addTearDown(container.dispose);
      container.listen(strategyPageSessionProvider, (_, __) {});
      await container.read(remoteEditorSnapshotProvider.future);
      container
          .read(strategyOpQueueProvider.notifier)
          .setActiveStrategy('cloud-strategy', accountId: 'account-a');
      container
          .read(strategyProvider.notifier)
          .setFromState(const StrategyState(
            strategyId: 'cloud-strategy',
            strategyName: 'Cloud Strategy',
            source: StrategySource.cloud,
            storageDirectory: null,
            isOpen: true,
          ));
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, repository.batches);
    }

    /// Every op sent for [key] in [batches], in order.
    List<StrategyOp> sentFor(
      List<List<StrategyOp>> batches,
      EntitySyncKey key,
    ) =>
        [
          for (final batch in batches)
            ...batch.where((op) => EntitySyncKey.forStrategyOp(op) == key),
        ];

    /// The edit to [key] the server refused as deleted waits in attention,
    /// with its conflict.
    Future<void> refusedAsDeleted(
      ProviderContainer container,
      List<List<StrategyOp>> batches,
      EntitySyncKey key,
    ) async {
      StrategyOpQueueState queueState() =>
          container.read(strategyOpQueueProvider);
      await _until(() => queueState().attentionByEntityKey.containsKey(key));
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      expect(sentFor(batches, key).single.kind, StrategyOpKind.patch);
      expect(
        queueState()
            .lastAckBatch
            .singleWhere((acked) => acked.entityKey == key)
            .ack,
        isA<RejectedOpAck>().having(
            (ack) => ack.rejectionReason, 'reason', OpRejectionReason.deleted),
      );
      expect(container.read(strategyConflictProvider), hasLength(1));
    }

    /// The edit to [key] the server refused as deleted waits in attention,
    /// with its conflict; Keep mine then sends it again. Returns the op it
    /// sent, once it has landed.
    Future<StrategyOp> refusedThenKeptMine(
      ProviderContainer container,
      List<List<StrategyOp>> batches,
      EntitySyncKey key,
    ) async {
      StrategyOpQueueState queueState() =>
          container.read(strategyOpQueueProvider);
      List<StrategyOp> sent() => sentFor(batches, key);
      await refusedAsDeleted(container, batches, key);

      final opQueue = container.read(strategyOpQueueProvider.notifier);
      await opQueue.retryRejected(flushImmediately: false);
      await opQueue.flushNow();
      await _until(() => queueState().pending.isEmpty && sent().length == 2);
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      expect(queueState().attentionByEntityKey, isEmpty);
      expect(queueState().needsAttention, isFalse);
      return sent().last;
    }

    test(
        'Keep mine restores a lineup a teammate deleted while the user '
        'edited it', () async {
      final page = _page('page-1', 0);
      server =
          _FakeServer(page.publicId, lineups: [_lineup(page.publicId, 'a')]);
      final (container, batches) = await openOnRealQueue(page);
      LineUpLink? onScreen() =>
          container.read(lineUpProvider).linkById('link-a');
      expect(onScreen(), isNotNull);

      // A teammate deletes the lineup; this canvas has not read that yet.
      server.teammateDelete('link-a');
      expect(server.row('link-a').revision, 2);

      // The user edits its notes. The server refuses the change to the
      // tombstone rather than store an edit nobody would see; the user still
      // sees their work.
      container
          .read(lineUpProvider.notifier)
          .updateLink(onScreen()!.copyWith(notes: 'mine'));
      final restore = await refusedThenKeptMine(
          container, batches, _lineupKey(page.publicId, 'a'));

      // Keep mine brought it back over the tombstone, as the user has it.
      expect(restore, isA<LineupAddOp>());
      expect((restore as LineupAddOp).expectedLineupRevision, 2);
      expect(cloudPayloadData(restore.payload)['notes'], 'mine');
      final row = server.row('link-a');
      expect(row.deleted, isFalse);
      expect(row.revision, 3);
      expect(cloudPayloadData(row.payload)['notes'], 'mine');
      expect(lineUpGraphFromRemoteLineups(server.liveRows).links.single.notes,
          'mine');
      expect(onScreen()?.notes, 'mine');
    });

    test(
        'Keep mine restores an element a teammate deleted while the user '
        'moved it', () async {
      final page = _page('page-1', 0);
      server = _FakeServer(page.publicId,
          elements: [_textElement(page.publicId, 'text-a', 'hello')]);
      final (container, batches) = await openOnRealQueue(page);
      PlacedText? onScreen() => container
          .read(textProvider)
          .where((text) => text.id == 'text-a')
          .firstOrNull;
      expect(onScreen(), isNotNull);

      // A teammate deletes the text; this canvas has not read that yet.
      server.teammateDeleteElement('text-a');

      // The user moves it.
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'text-a');
      final restore = await refusedThenKeptMine(
          container, batches, EntitySyncKey.element(page.publicId, 'text-a'));

      // Keep mine brought it back over the tombstone, where the user put it.
      expect(restore, isA<ElementAddOp>());
      expect((restore as ElementAddOp).expectedElementRevision, 2);
      final element = server.element('text-a');
      expect(element.deleted, isFalse);
      expect(element.revision, 3);
      expect(element.payload, restore.payload);
      expect(onScreen()?.position, const Offset(300, 300));
      expect(onScreen()?.text, 'hello');
    });

    /// After [refusedAsDeleted], the user deletes the item on the canvas
    /// with [delete]. Both sides agree it is gone, so the refused change is
    /// settled, in the queue and in [store], and Keep mine then brings
    /// nothing back.
    Future<void> deletedAfterRefusal(
      ProviderContainer container,
      List<List<StrategyOp>> batches,
      MemoryDurableStrategyOutboxStore store,
      EntitySyncKey key,
      void Function() delete,
    ) async {
      StrategyOpQueueState queueState() =>
          container.read(strategyOpQueueProvider);
      Iterable<DurableOutboxRecord> stored() =>
          store.load().records.where((record) => record.entityKey == key);
      await refusedAsDeleted(container, batches, key);
      expect(stored().single.status, DurableOutboxStatus.attention);

      delete();
      await _until(() =>
          !queueState().attentionByEntityKey.containsKey(key) &&
          queueState().pending.isEmpty);
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      expect(queueState().attentionByEntityKey, isEmpty);
      expect(queueState().successorByEntityKey, isEmpty);
      expect(queueState().needsAttention, isFalse);
      expect(stored(), isEmpty);
      // Its refusal is not announced after the fact either.
      expect(container.read(strategyConflictProvider), isEmpty);

      // Keep mine has nothing left to send.
      final opQueue = container.read(strategyOpQueueProvider.notifier);
      await opQueue.retryRejected(flushImmediately: false);
      await opQueue.flushNow();
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      expect(
        sentFor(batches, key).where((op) => op.kind == StrategyOpKind.add),
        isEmpty,
      );
      expect(queueState().pending, isEmpty);
      expect(stored(), isEmpty);
    }

    test(
        'a lineup the user deletes after a teammate deleted it and their '
        'edit was refused stays deleted through Keep mine', () async {
      final page = _page('page-1', 0);
      server =
          _FakeServer(page.publicId, lineups: [_lineup(page.publicId, 'a')]);
      final store = MemoryDurableStrategyOutboxStore();
      final (container, batches) = await openOnRealQueue(page, store: store);
      LineUpLink? onScreen() =>
          container.read(lineUpProvider).linkById('link-a');

      // A teammate deletes the lineup while the user edits its notes.
      server.teammateDelete('link-a');
      container
          .read(lineUpProvider.notifier)
          .updateLink(onScreen()!.copyWith(notes: 'mine'));
      await deletedAfterRefusal(
        container,
        batches,
        store,
        _lineupKey(page.publicId, 'a'),
        () => container.read(lineUpProvider.notifier).deleteLink('link-a'),
      );

      expect(onScreen(), isNull);
      expect(server.row('link-a').deleted, isTrue);
      expect(server.row('link-a').revision, 2);
      expect(server.liveRows, isEmpty);
    });

    test(
        'an element the user deletes after a teammate deleted it and their '
        'move was refused stays deleted through Keep mine', () async {
      final page = _page('page-1', 0);
      server = _FakeServer(page.publicId,
          elements: [_textElement(page.publicId, 'text-a', 'hello')]);
      final store = MemoryDurableStrategyOutboxStore();
      final (container, batches) = await openOnRealQueue(page, store: store);
      PlacedText? onScreen() => container
          .read(textProvider)
          .where((text) => text.id == 'text-a')
          .firstOrNull;

      // A teammate deletes the text while the user moves it.
      server.teammateDeleteElement('text-a');
      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'text-a');
      await deletedAfterRefusal(
        container,
        batches,
        store,
        EntitySyncKey.element(page.publicId, 'text-a'),
        () =>
            container.read(textProvider.notifier).removeTextAsAction('text-a'),
      );

      expect(onScreen(), isNull);
      expect(server.element('text-a').deleted, isTrue);
      expect(server.element('text-a').revision, 2);
    });

    test(
        'a recovered edit to a lineup on a split spot is sent as it was, and '
        'opening the page writes nothing else', () async {
      final page = _page('page-1', 0);
      server =
          _FakeServer(page.publicId, lineups: divergedFanIn(page.publicId));
      final rowA = server.row('link-a');
      final rowB = server.row('link-b');
      final bKey = keyOf(page, 'link-b');
      // Before a restart, the user's notes edit to B was saved to the outbox
      // but never sent.
      final recovered = LineupPatchOp(
        opId: 'recovered-notes',
        lineupPublicId: 'link-b',
        pagePublicId: page.publicId,
        payload:
            _editedLineup(rowB, (data) => data['notes'] = 'recovered').payload,
        expectedLineupRevision: rowB.revision,
      );
      final store = MemoryDurableStrategyOutboxStore();
      await store.put(DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        entityKey: bKey,
        pending: PendingOp(op: recovered, clientId: 'client-before-restart'),
        status: DurableOutboxStatus.queued,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ));

      // Its send waits while the page opens.
      final hold = Completer<void>();
      final (container, batches) =
          await openOnRealQueue(page, store: store, hold: hold);
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      StrategyOpQueueState queueState() =>
          container.read(strategyOpQueueProvider);
      bool isLineup(StrategyOp op) =>
          EntitySyncKey.forStrategyOp(op)?.kind == EntitySyncKeyKind.lineup;

      // The page draws B on its own copy of the landing, and the recovered
      // edit is the only lineup work: nothing replaced it, nothing joined it.
      expect(container.read(lineUpProvider).landings.map((l) => l.id),
          ['landing', 'landing@link-b']);
      expect(
        [
          for (final pending in queueState().pending)
            if (isLineup(pending.op)) pending.op.opId,
        ],
        ['recovered-notes'],
      );
      expect(
        [for (final record in store.load().records) record.pending.op.opId],
        ['recovered-notes'],
      );

      hold.complete();
      await _until(() => queueState().pending.isEmpty);
      for (var i = 0; i < 10; i++) {
        await _settle();
      }

      // Only the recovered edit was ever sent for a lineup, as it was saved.
      expect(
        [
          for (final batch in batches)
            for (final op in batch)
              if (isLineup(op)) op.opId,
        ],
        ['recovered-notes'],
      );
      expect(server.received.single.payload, recovered.payload);
      expect(server.row('link-b').revision, rowB.revision + 1);
      expect(
          cloudPayloadData(server.row('link-b').payload)['notes'], 'recovered');
      expect(server.row('link-a').revision, rowA.revision);
      expect(
        canonicalCloudJsonEncode(server.row('link-a').payload),
        canonicalCloudJsonEncode(rowA.payload),
      );
      expect(
        container.read(lineUpProvider).linkById('link-b')!.notes,
        'recovered',
      );
      expect(landingAt(container, 'landing@link-b'), older);
      expect(landingAt(container, 'landing'), newer);
    });

    test(
        'an edit whose answer was lost is answered at the revision it landed '
        'at, so the edit behind it cannot overwrite a teammate', () async {
      final page = _page('page-1', 0);
      server =
          _FakeServer(page.publicId, lineups: [_lineup(page.publicId, 'a')]);
      final hold = Completer<void>();
      final (container, batches) = await openOnRealQueue(page, hold: hold);
      final key = _lineupKey(page.publicId, 'a');
      StrategyOpQueueState queueState() =>
          container.read(strategyOpQueueProvider);
      LineUpLink onScreen() =>
          container.read(lineUpProvider).linkById('link-a')!;

      // The user's notes edit reaches the server, which takes it at
      // revision 2, but the answer is lost; a teammate renames the lineup
      // right after.
      repository.loseNextAnswer = () =>
          server.teammateEdit('link-a', (data) => data['name'] = 'theirs');
      container
          .read(lineUpProvider.notifier)
          .updateLink(onScreen().copyWith(notes: 'one'));
      await _until(() => queueState().inFlightByEntityKey.containsKey(key));
      // While it is on its way, the user edits again; that waits behind it.
      container
          .read(lineUpProvider.notifier)
          .updateLink(onScreen().copyWith(notes: 'two'));
      await _until(() => queueState().successorByEntityKey.containsKey(key));
      hold.complete();

      // The first edit is sent again and answered as landed at revision 2,
      // so the second goes against revision 2: refused, not stored over the
      // teammate's name.
      await _until(() => queueState().attentionByEntityKey.containsKey(key));
      for (var i = 0; i < 10; i++) {
        await _settle();
      }
      final sent = sentFor(batches, key);
      expect(sent, hasLength(3));
      expect(sent[1].opId, sent[0].opId);
      expect(cloudPayloadData(sent[2].payload)['notes'], 'two');
      expect((sent[2] as LineupPatchOp).expectedLineupRevision, 2);
      final row = server.row('link-a');
      expect(row.revision, 3);
      expect(cloudPayloadData(row.payload)['name'], 'theirs');
      expect(cloudPayloadData(row.payload)['notes'], 'one');
      expect(container.read(strategyConflictProvider), hasLength(1));
    });
  });

  group('lineup history across rehydration', () {
    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)>
        openWithLineup() async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          lineups: [_lineup(page.publicId, 'lineup-a')],
        ),
      ));
      final container = await _cloudContainer(
        remote: remote,
        queue: _FakeStrategyOpQueueNotifier(),
      );
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      expect(container.read(lineUpProvider).origins.single.id, 'lineup-a');
      return (container, remote, page);
    }

    /// The server accepted the local edit and the page rehydrates from the
    /// new snapshot, keeping history (a cloud ack).
    Future<void> ackAndRehydrate(
      ProviderContainer container,
      _FakeRemoteEditorNotifier remote,
      RemotePage page,
      List<RemoteLineup> lineups,
    ) async {
      container.read(strategySaveStateProvider.notifier).markPersisted();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(page, contentRevision: 2, lineups: lineups),
      ));
      await _settle();
    }

    test('undoing a lineup delete still restores it after an ack', () async {
      final (container, remote, page) = await openWithLineup();

      container.read(lineUpProvider.notifier).deleteOrigin('lineup-a');
      expect(container.read(lineUpProvider).origins, isEmpty);
      await ackAndRehydrate(container, remote, page, const []);
      expect(container.read(lineUpProvider).origins, isEmpty);

      container.read(actionProvider.notifier).undoAction();

      final lineUps = container.read(lineUpProvider);
      expect(lineUps.origins.single.id, 'lineup-a');
      expect(lineUps.links.single.id, 'link-lineup-a');
      expect(lineUps.landings, hasLength(1));

      container.read(actionProvider.notifier).redoAction();
      expect(container.read(lineUpProvider).links, isEmpty);
      await _settle();
    });

    test('undoing a marker move keeps a teammate lineup that arrived since',
        () async {
      final (container, remote, page) = await openWithLineup();
      const moved = Offset(200, 220);

      container
          .read(lineUpProvider.notifier)
          .updateOriginAgentPosition('lineup-a', moved);
      // The move lands and a teammate's lineup B arrives with it.
      await ackAndRehydrate(container, remote, page, [
        _lineup(page.publicId, 'lineup-a', agentPosition: moved, revision: 2),
        _lineup(page.publicId, 'lineup-b', sortIndex: 1),
      ]);
      expect(
        container.read(lineUpProvider).origins.map((origin) => origin.id),
        ['lineup-a', 'lineup-b'],
      );

      container.read(actionProvider.notifier).undoAction();

      final lineUps = container.read(lineUpProvider);
      expect(
        lineUps.origins.map((origin) => origin.id),
        ['lineup-a', 'lineup-b'],
      );
      expect(
        lineUps.originById('lineup-a')!.agent.position,
        const Offset(10, 20),
      );
      final desired =
          container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: page.publicId,
              );
      expect(desired, isNotNull);
      expect(desired!.values.whereType<LineupDeleteOp>(), isEmpty);
      expect(
        desired[_lineupKey(page.publicId, 'lineup-a')],
        isA<LineupPatchOp>(),
      );
      expect(
        desired.keys
            .where((key) => key.entityId?.endsWith('lineup-b') ?? false),
        isEmpty,
      );
      await _settle();
    });
  });

  test('unhydrated canvas cannot author a remote lineup deletion', () async {
    final page = _page('page-1', 0);
    final container = await _syncContainer(
      remote: _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          lineups: [_lineup(page.publicId, 'lineup-1')],
        ),
      )),
      queue: _FakeStrategyOpQueueNotifier(),
    );
    container.read(activePageLiveSyncProvider.notifier).setContext(
          strategyPublicId: 'cloud-strategy',
          activePageId: page.publicId,
        );

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, isNull);
  });

  test('new remote lineup is not inferred as a local deletion', () async {
    final page = _page('page-1', 0);
    final before = _editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote'),
    );
    final remote = _FakeRemoteEditorNotifier(before);
    final container = await _cloudContainer(
      remote: remote,
      queue: _FakeStrategyOpQueueNotifier(),
    );
    await container
        .read(strategyPageSessionProvider.notifier)
        .initializeForStrategy(
          strategyId: 'cloud-strategy',
          source: StrategySource.cloud,
          selectFirstPageIfNeeded: true,
        );

    container.read(strategySaveStateProvider.notifier).markDirty();
    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        text: 'remote',
        contentRevision: 2,
        lineups: [_lineup(page.publicId, 'lineup-1')],
      ),
    ));

    final desired =
        container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
              strategyPublicId: 'cloud-strategy',
              pageId: page.publicId,
            );

    expect(desired, isNotNull);
    expect(
      desired!.keys.where((key) => key.kind == EntitySyncKeyKind.lineup),
      isEmpty,
    );
  });

  test('page switch persists old intent and never waits indefinitely',
      () async {
    final pageOne = _page('page-1', 0);
    final pageTwo = _page('page-2', 1);
    final first = _pageSnapshot(pageOne, text: 'one');
    final second = _pageSnapshot(pageTwo, text: 'two');
    final remote = _FakeRemoteEditorNotifier(
      _editorSnapshot(pages: [pageOne, pageTwo], activePage: first),
      pageCatalog: {'page-1': first, 'page-2': second},
    );
    final queue = _FakeStrategyOpQueueNotifier(blockFlush: true);
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-page-1', position: const Offset(5, 5))..text = 'one',
    ]);
    container
        .read(textDraftProvider.notifier)
        .setDraft('text-page-1', 'unsent draft');

    await session.setActivePage('page-2').timeout(const Duration(seconds: 2));
    expect(session.activePageId, 'page-2');
    expect(remote.selectedPageIds, contains('page-2'));
    expect(container.read(textProvider).single.text, 'two');
    expect(container.read(textDraftProvider), isEmpty);
    expect(queue.flushNowCount, 1);
    expect(
      container.read(strategyOpQueueProvider).pending.any((pending) =>
          pending.op.entityPublicId == 'text-page-1' &&
          pending.op.payload.toString().contains('unsent draft')),
      isTrue,
    );
  });

  test('persisted overlay wins over a late remote active-page base', () async {
    final page = _page('page-1', 0);
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote-before'),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'local', position: const Offset(5, 5))
        ..text = 'local-intent',
    ]);
    await session.flushCurrentPage();

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(page, text: 'remote-after'),
    ));
    await _settle();
    expect(container.read(textProvider).single.text, 'local-intent');
    expect(container.read(strategyOpQueueProvider).pending, isNotEmpty);
  });

  test(
      'collaborator edits stay based on the page this client actually hydrated',
      () async {
    final page = _page('page-1', 0);
    const localTextId = 'local-text';
    const collaboratorTextId = 'collaborator-text';
    final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(
            page.publicId,
            localTextId,
            'shared-before',
            worldSized: true,
          ),
          _textElement(
            page.publicId,
            collaboratorTextId,
            'collaborator-before',
            sortIndex: 1,
            worldSized: true,
          ),
        ],
      ),
    ));
    final queue = _FakeStrategyOpQueueNotifier();
    final container = await _cloudContainer(remote: remote, queue: queue);
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'cloud-strategy',
      source: StrategySource.cloud,
      selectFirstPageIfNeeded: true,
    );

    container.read(textProvider.notifier).commitText(
          localTextId,
          'this-client-edit',
        );
    await _settle();

    remote.setSnapshot(_editorSnapshot(
      pages: [page],
      activePage: _pageSnapshot(
        page,
        elements: [
          _textElement(
            page.publicId,
            localTextId,
            'collaborator-winner',
            revision: 2,
            worldSized: true,
          ),
          _textElement(
            page.publicId,
            collaboratorTextId,
            'collaborator-after',
            revision: 2,
            sortIndex: 1,
            worldSized: true,
          ),
        ],
      ),
    ));
    await _settle();

    expect(
      container
          .read(textProvider)
          .firstWhere((text) => text.id == collaboratorTextId)
          .text,
      'collaborator-before',
    );

    await session.flushCurrentPage();

    final elementOps = container
        .read(strategyOpQueueProvider)
        .queuedByEntityKey
        .entries
        .where((entry) => entry.key.kind == EntitySyncKeyKind.element)
        .toList(growable: false);
    expect(elementOps, hasLength(1));
    expect(elementOps.single.key.entityId, localTextId);
    expect(elementOps.single.value.pending.op.expectedRevision, 1);
    expect(
      elementOps.single.value.pending.op.payload.toString(),
      contains('this-client-edit'),
    );
  });

  test('local mode page switching keeps its shipped Hive shape', () async {
    final box = await _openStrategyBox();
    final now = DateTime.utc(2026);
    StrategyPage localPage(String id, int index, String value) => StrategyPage(
          id: id,
          name: 'Page ${index + 1}',
          drawingData: const [],
          agentData: const [],
          abilityData: const [],
          textData: [
            PlacedText(id: 'text-$id', position: const Offset(1, 2))
              ..text = value,
          ],
          imageData: const [],
          utilityData: const [],
          sortIndex: index,
          isAttack: true,
          settings: StrategySettings(),
        );
    await box.put(
      'local-strategy',
      StrategyData(
        id: 'local-strategy',
        name: 'Local',
        mapData: MapValue.ascent,
        versionNumber: 1,
        lastEdited: now,
        folderID: null,
        pages: [
          localPage('page-1', 0, 'one'),
          localPage('page-2', 1, 'two'),
        ],
      ),
    );
    final container = ProviderContainer(overrides: [
      strategyOpQueueProvider.overrideWith(
        () => _FakeStrategyOpQueueNotifier(),
      ),
    ]);
    addTearDown(container.dispose);
    container.read(strategyProvider.notifier).setFromState(const StrategyState(
          strategyId: 'local-strategy',
          strategyName: 'Local',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ));
    final session = container.read(strategyPageSessionProvider.notifier);
    await session.initializeForStrategy(
      strategyId: 'local-strategy',
      source: StrategySource.local,
      selectFirstPageIfNeeded: true,
    );
    expect(container.read(textProvider).single.text, 'one');
    await session.setActivePage('page-2');
    expect(container.read(textProvider).single.text, 'two');
    expect(box.get('local-strategy')!.pages, hasLength(2));
  });

  group('undo on a shared page keeps teammates\' work', () {
    /// Page settings that round-trip exactly, so live sync authors nothing
    /// for them unless undo changes them.
    CloudPayload settingsWith({
      double agentSize = 30,
      double abilitySize = 20,
    }) =>
        StrategySettings(agentSize: agentSize, abilitySize: abilitySize)
            .toJson();

    Map<String, dynamic> payloadOf(Object value) {
      return switch (value) {
        PlacedAgentNode() => {...value.toJson(), 'elementType': 'agent'},
        PlacedAbility() => {...value.toJson(), 'elementType': 'ability'},
        DrawingElement() => {
            ...(jsonDecode(DrawingProvider.objectToJson([value])) as List)
                .single as Map<String, dynamic>,
            'elementType': 'drawing',
          },
        PlacedText() => {...value.toJson(), 'elementType': 'text'},
        PlacedImage() => {
            ...cloudImagePayloadFromPlacedImage(value),
            'elementType': 'image',
          },
        PlacedUtility() => {...value.toJson(), 'elementType': 'utility'},
        _ => throw ArgumentError(value.runtimeType),
      };
    }

    String idOf(Object value) => switch (value) {
          PlacedWidget() => value.id,
          DrawingElement() => value.id,
          _ => throw ArgumentError(value.runtimeType),
        };

    RemoteElement element(
      RemotePage page,
      Object value, {
      int revision = 1,
      int sortIndex = 0,
    }) {
      final payload = payloadOf(value);
      final kind = payload['elementType'] as String;
      return RemoteElement(
        publicId: idOf(value),
        strategyPublicId: 'cloud-strategy',
        pagePublicId: page.publicId,
        elementType: kind,
        payload: cloudElementPayload(kind: kind, data: payload),
        sortIndex: sortIndex,
        revision: revision,
        deleted: false,
      );
    }

    /// Everything on the local canvas outside lineups.
    List<Object> canvasOf(ProviderContainer container) => [
          ...container.read(agentProvider),
          ...container.read(abilityProvider),
          ...container.read(drawingProvider).elements,
          ...container.read(textProvider),
          ...container.read(placedImageProvider).images,
          ...container.read(utilityProvider),
        ];

    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)> open(
      List<Object> objects, {
      List<RemoteLineup> lineups = const [],
    }) async {
      final page = _page('page-1', 0);
      final remote = _FakeRemoteEditorNotifier(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          settings: settingsWith(),
          elements: [
            for (var i = 0; i < objects.length; i++)
              element(page, objects[i], sortIndex: i),
          ],
          lineups: lineups,
        ),
      ));
      final container = await _cloudContainer(
        remote: remote,
        queue: _FakeStrategyOpQueueNotifier(),
      );
      // Let queued sync work finish before the container is disposed.
      addTearDown(_settle);
      await container
          .read(strategyPageSessionProvider.notifier)
          .initializeForStrategy(
            strategyId: 'cloud-strategy',
            source: StrategySource.cloud,
            selectFirstPageIfNeeded: true,
          );
      return (container, remote, page);
    }

    /// This client's edits land and the page rehydrates with the server's
    /// copy: the local canvas as sent, with [teammate] applied on top (a
    /// teammate's change arriving in the same round).
    Future<void> land(
      ProviderContainer container,
      _FakeRemoteEditorNotifier remote,
      RemotePage page, {
      List<Object> Function(List<Object> canvas)? teammate,
      CloudPayload? settings,
      List<RemoteLineup> lineups = const [],
    }) async {
      final canvas = canvasOf(container);
      final stored = teammate == null ? canvas : teammate(canvas);
      container.read(strategySaveStateProvider.notifier).markPersisted();
      remote.setSnapshot(_editorSnapshot(
        pages: [page],
        activePage: _pageSnapshot(
          page,
          contentRevision: 2,
          settings:
              settings ?? container.read(strategySettingsProvider).toJson(),
          elements: [
            for (var i = 0; i < stored.length; i++)
              element(page, stored[i], revision: 2, sortIndex: i),
          ],
          lineups: lineups,
        ),
      ));
      await _settle();
    }

    Map<EntitySyncKey, StrategyOp> desiredOps(
      ProviderContainer container,
      RemotePage page,
    ) {
      return container.read(activePageLiveSyncProvider.notifier).syncLocalPage(
                strategyPublicId: 'cloud-strategy',
                pageId: page.publicId,
              ) ??
          const {};
    }

    /// [id] is on the canvas and live sync authors no deletion for it.
    void expectKept(ProviderContainer container, RemotePage page, String id) {
      expect(canvasOf(container).map(idOf), contains(id));
      expect(
        desiredOps(container, page)[EntitySyncKey.element(page.publicId, id)],
        isNot(isA<ElementDeleteOp>()),
      );
    }

    PlacedAgent jett(String id) => PlacedAgent(
          id: id,
          type: AgentType.jett,
          position: const Offset(10, 20),
        );

    PlacedUtility cone(String id) => PlacedUtility(
          id: id,
          type: UtilityType.viewCone90,
          position: const Offset(40, 40),
        );

    ActionProvider history(ProviderContainer container) =>
        container.read(actionProvider.notifier);

    test('undoing an agent move keeps an agent a teammate added', () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, jett('sova')]);

      history(container).undoAction();

      expect(
        container
            .read(agentProvider)
            .firstWhere((a) => a.id == 'jett')
            .position,
        const Offset(10, 20),
      );
      expectKept(container, page, 'sova');
    });

    test('undoing an agent move keeps a teammate marking it dead', () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      await land(container, remote, page,
          teammate: (canvas) => [
                for (final object in canvas)
                  if (object is PlacedAgent)
                    (object.copyWith()..state = AgentState.dead)
                  else
                    object,
              ]);

      history(container).undoAction();

      final agent = container.read(agentProvider).single;
      expect(agent.position, const Offset(10, 20));
      expect(agent.state, AgentState.dead);

      history(container).redoAction();
      final redone = container.read(agentProvider).single;
      expect(redone.position, const Offset(200, 200));
      expect(redone.state, AgentState.dead);
    });

    // A move, undone and redone, against a teammate's change to another
    // field of the same object: [field] set to [value] in its payload.
    final moveCases = <(String, Object, String, Object)>[
      (
        'ability',
        PlacedAbility(
          id: 'mine',
          data: AgentData.agents[AgentType.jett]!.abilities.first,
          position: const Offset(10, 20),
        ),
        'isAlly',
        false,
      ),
      (
        'text',
        PlacedText(id: 'mine', position: const Offset(10, 20))..text = 'mine',
        'text',
        'theirs',
      ),
      (
        'image',
        PlacedImage(
          id: 'mine',
          position: const Offset(10, 20),
          aspectRatio: 1,
          scale: ImageScalePolicy.defaultWidth,
          fileExtension: '.png',
        ),
        'scale',
        ImageScalePolicy.defaultWidth + 40,
      ),
      (
        'utility',
        PlacedUtility(
          id: 'mine',
          type: UtilityType.viewCone90,
          position: const Offset(10, 20),
        ),
        'isAlly',
        false,
      ),
    ];
    for (final (kind, object, field, value) in moveCases) {
      test('undoing a $kind move keeps a teammate change to its $field',
          () async {
        final (container, remote, page) = await open([object]);
        void move(Offset to) => switch (kind) {
              'ability' => container
                  .read(abilityProvider.notifier)
                  .updatePosition(to, 'mine'),
              'text' => container
                  .read(textProvider.notifier)
                  .updatePosition(to, 'mine'),
              'image' => container
                  .read(placedImageProvider.notifier)
                  .updatePosition(to, 'mine'),
              _ => container
                  .read(utilityProvider.notifier)
                  .updatePosition(to, 'mine'),
            };
        Map<String, dynamic> mine() => payloadOf(
            canvasOf(container).singleWhere((o) => idOf(o) == 'mine'));
        Object withField(Object source) {
          final json = {...payloadOf(source), field: value};
          return switch (kind) {
            'ability' => PlacedAbility.fromJson(json),
            'text' => PlacedText.fromJson(json),
            'image' => PlacedImage.fromJson(json),
            _ => PlacedUtility.fromJson(json),
          };
        }

        move(const Offset(200, 200));
        await land(container, remote, page,
            teammate: (canvas) => [for (final o in canvas) withField(o)]);
        expect(mine()[field], value);

        history(container).undoAction();
        expect(mine()['position'], {'dx': 10.0, 'dy': 20.0});
        expect(mine()[field], value);

        history(container).redoAction();
        expect(mine()['position'], {'dx': 200.0, 'dy': 200.0});
        expect(mine()[field], value);
      });
    }

    test('undoing a view cone conversion keeps an agent a teammate added',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      history(container).performTransaction(
        groups: const [ActionGroup.agent],
        mutation: () =>
            container.read(agentProvider.notifier).convertPlainAgentToViewCone(
                  id: 'jett',
                  presetType: UtilityType.viewCone90,
                  rotation: 0,
                  length: 50,
                ),
      );
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, jett('sova')]);

      history(container).undoAction();

      expect(
        container.read(agentProvider).firstWhere((a) => a.id == 'jett'),
        isNot(isA<PlacedViewConeAgent>()),
      );
      expectKept(container, page, 'sova');

      history(container).redoAction();
      expect(
        container.read(agentProvider).firstWhere((a) => a.id == 'jett'),
        isA<PlacedViewConeAgent>(),
      );
      expectKept(container, page, 'sova');
    });

    test('undoing a cone dropped on an agent keeps a teammate utility',
        () async {
      final (container, remote, page) =
          await open([jett('jett'), cone('cone')]);

      history(container).performTransaction(
        groups: const [ActionGroup.agent, ActionGroup.utility],
        mutation: () {
          container
              .read(utilityProvider.notifier)
              .removeUtilityAsAction('cone');
          container.read(agentProvider.notifier).convertPlainAgentToViewCone(
                id: 'jett',
                presetType: UtilityType.viewCone90,
                rotation: 0,
                length: 50,
              );
        },
      );
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, cone('teammate-cone')]);

      history(container).undoAction();

      expect(
        container.read(utilityProvider).map((u) => u.id),
        containsAll(['cone', 'teammate-cone']),
      );
      expect(
        container.read(agentProvider).single,
        isNot(isA<PlacedViewConeAgent>()),
      );
      expectKept(container, page, 'teammate-cone');

      history(container).redoAction();
      expect(
        container.read(utilityProvider).map((u) => u.id),
        ['teammate-cone'],
      );
      expectKept(container, page, 'teammate-cone');
    });

    test('undoing a size change keeps a teammate size change', () async {
      final (container, remote, page) = await open([jett('jett')]);

      final settings = container.read(strategySettingsProvider.notifier);
      history(container).performTransaction(
        groups: const [ActionGroup.strategySettings],
        mutation: () => settings.updateAgentSize(40),
      );
      await land(container, remote, page,
          settings: settingsWith(agentSize: 40, abilitySize: 28));
      expect(container.read(strategySettingsProvider).abilitySize, 28);

      history(container).undoAction();

      expect(container.read(strategySettingsProvider).agentSize, 30);
      expect(container.read(strategySettingsProvider).abilitySize, 28);

      history(container).redoAction();
      expect(container.read(strategySettingsProvider).agentSize, 40);
      expect(container.read(strategySettingsProvider).abilitySize, 28);
    });

    test('undoing a utility elevation change still works after it lands',
        () async {
      final (container, remote, page) = await open([cone('cone')]);

      container
          .read(utilityProvider.notifier)
          .updateViewConeElevation('cone', 150);
      await land(container, remote, page);

      history(container).undoAction();
      expect(container.read(utilityProvider).single.visionElevation, isNull);

      history(container).redoAction();
      expect(container.read(utilityProvider).single.visionElevation, 150);
    });

    test('an edit before a deletion stays undoable after the deletion lands',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      container.read(agentProvider.notifier).removeAgentAsAction('jett');
      await land(container, remote, page);
      expect(container.read(agentProvider), isEmpty);

      history(container).undoAction();
      expect(
        container.read(agentProvider).single.position,
        const Offset(200, 200),
      );

      history(container).undoAction();
      expect(
        container.read(agentProvider).single.position,
        const Offset(10, 20),
      );
    });

    test('undo and redo skip an edit whose object a teammate deleted',
        () async {
      final (container, remote, page) =
          await open([jett('jett'), jett('sova')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'jett');
      await land(container, remote, page,
          teammate: (canvas) => [
                for (final object in canvas)
                  if (idOf(object) != 'jett') object,
              ]);

      history(container).undoAction();
      history(container).redoAction();

      expect(container.read(agentProvider).map((a) => a.id), ['sova']);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'jett')],
        isNull,
      );
    });

    // Bulk clear, per group: a teammate's object of the cleared kind arrives
    // after the clear lands.
    final clearCases = <(ActionGroup, Object Function(String id))>[
      (ActionGroup.agent, jett),
      (
        ActionGroup.ability,
        (id) => PlacedAbility(
              id: id,
              data: AgentData.agents[AgentType.jett]!.abilities.first,
              position: const Offset(60, 60),
            ),
      ),
      (
        ActionGroup.drawing,
        (id) => FreeDrawing(
              id: id,
              color: Colors.red,
              isDotted: false,
              hasArrow: false,
              listOfPoints: const [Offset.zero, Offset(10, 10)],
            ),
      ),
      (
        ActionGroup.text,
        (id) => PlacedText(id: id, position: const Offset(70, 70))..text = id,
      ),
      (
        ActionGroup.image,
        (id) => PlacedImage(
              id: id,
              position: const Offset(80, 80),
              aspectRatio: 1,
              scale: ImageScalePolicy.defaultWidth,
              fileExtension: '.png',
            ),
      ),
      (ActionGroup.utility, cone),
    ];
    for (final (group, build) in clearCases) {
      test('undoing a ${group.name} clear keeps one a teammate added',
          () async {
        final (container, remote, page) = await open([
          build('mine'),
          if (group != ActionGroup.agent) jett('jett'),
        ]);

        history(container).clearGroupAsAction(group);
        expect(canvasOf(container).map(idOf), isNot(contains('mine')));
        await land(container, remote, page,
            teammate: (canvas) => [...canvas, build('theirs')]);

        history(container).undoAction();
        expect(
          canvasOf(container).map(idOf),
          containsAll(['mine', 'theirs']),
        );
        expectKept(container, page, 'theirs');

        history(container).redoAction();
        expect(canvasOf(container).map(idOf), isNot(contains('mine')));
        expectKept(container, page, 'theirs');
      });
    }

    /// [canvas] with the object [id] replaced by [edit] of it.
    List<Object> editing(
      List<Object> canvas,
      String id,
      Object Function(Object object) edit,
    ) =>
        [for (final o in canvas) idOf(o) == id ? edit(o) : o];

    /// [canvas] without the object [id].
    List<Object> without(List<Object> canvas, String id) => [
          for (final o in canvas)
            if (idOf(o) != id) o
        ];

    Object dead(Object agent) =>
        (agent as PlacedAgent).copyWith()..state = AgentState.dead;

    PlacedAgent agentOn(ProviderContainer container, String id) =>
        container.read(agentProvider).singleWhere((a) => a.id == id)
            as PlacedAgent;

    test('undoing an ability visibility toggle keeps teammate toggles',
        () async {
      final ability = PlacedAbility(
        id: 'mine',
        data: AgentData.agents[AgentType.jett]!.abilities.first,
        position: const Offset(10, 20),
      );
      final (container, remote, page) = await open([ability]);
      AbilityVisualState visual() =>
          container.read(abilityProvider).single.visualState;
      Object toggled(Object object, String toggle) => PlacedAbility.fromJson({
            ...payloadOf(object),
            'visualState': {
              ...(object as PlacedAbility).visualState.toJson(),
              toggle: false,
            },
          });

      container.read(abilityProvider.notifier).updateVisualState(
            0,
            visual().copyWith(showRangeOutline: false),
          );
      await land(container, remote, page,
          teammate: (canvas) =>
              editing(canvas, 'mine', (o) => toggled(o, 'showRangeFill')));

      history(container).undoAction();
      expect(visual().showRangeOutline, isTrue);
      expect(visual().showRangeFill, isFalse);

      // Another teammate toggle lands between undo and redo.
      await land(container, remote, page,
          teammate: (canvas) =>
              editing(canvas, 'mine', (o) => toggled(o, 'showInnerFill')));
      history(container).redoAction();
      expect(visual().showRangeOutline, isFalse);
      expect(visual().showRangeFill, isFalse);
      expect(visual().showInnerFill, isFalse);

      history(container).undoAction();
      expect(visual().showRangeOutline, isTrue);
      expect(visual().showRangeFill, isFalse);
      expect(visual().showInnerFill, isFalse);
    });

    test('undoing a deletion leaves a teammate copy that is still there',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container.read(agentProvider.notifier).removeAgentAsAction('jett');
      // The teammate's edited copy wins on the server.
      final teammateCopy = dead(jett('jett'));
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, teammateCopy]);
      expect(agentOn(container, 'jett').state, AgentState.dead);

      history(container).undoAction();
      expect(agentOn(container, 'jett').state, AgentState.dead);

      // The undo restored nothing, so there is nothing for redo to remove.
      history(container).redoAction();
      expect(agentOn(container, 'jett').state, AgentState.dead);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'jett')],
        isNot(isA<ElementDeleteOp>()),
      );
    });

    test('redoing an addition brings back the copy the undo took away',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container.read(agentProvider.notifier).addAgent(jett('sova'));
      await land(container, remote, page,
          teammate: (canvas) => editing(canvas, 'sova', dead));

      history(container).undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      await land(container, remote, page);

      history(container).redoAction();
      expect(agentOn(container, 'sova').state, AgentState.dead);

      history(container).undoAction();
      history(container).redoAction();
      expect(agentOn(container, 'sova').state, AgentState.dead);
    });

    test('a clear undone and redone around a teammate edit keeps the edit',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      history(container).clearGroupAsAction(ActionGroup.agent);
      history(container).undoAction();
      await land(container, remote, page,
          teammate: (canvas) => editing(canvas, 'jett', dead));

      history(container).redoAction();
      expect(container.read(agentProvider), isEmpty);
      await land(container, remote, page);

      history(container).undoAction();
      expect(agentOn(container, 'jett').state, AgentState.dead);
    });

    test('undoing an addition a teammate deleted gives redo nothing to add',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container.read(agentProvider.notifier).addAgent(jett('sova'));
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'sova'));

      history(container).undoAction();
      history(container).redoAction();

      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'sova')],
        isNull,
      );
    });

    test(
        'redoing a clear after a teammate deleted a restored object '
        'does not bring it back on the next undo', () async {
      final (container, remote, page) =
          await open([jett('jett'), jett('sova')]);

      history(container).clearGroupAsAction(ActionGroup.agent);
      history(container).undoAction();
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'sova'));

      history(container).redoAction();
      expect(container.read(agentProvider), isEmpty);
      await land(container, remote, page);

      history(container).undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'sova')],
        isNull,
      );
    });

    test('a transaction whose object a teammate deleted leaves history',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      history(container).performTransaction(
        groups: const [ActionGroup.agent],
        mutation: () =>
            container.read(agentProvider.notifier).convertPlainAgentToViewCone(
                  id: 'jett',
                  presetType: UtilityType.viewCone90,
                  rotation: 0,
                  length: 50,
                ),
      );
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'jett'));

      expect(container.read(actionProvider), isEmpty);
    });

    test('undoing a clear leaves out history hydration dropped since',
        () async {
      final (container, remote, page) = await open([
        jett('jett'),
        PlacedText(id: 'note', position: const Offset(70, 70))..text = 'note',
      ]);

      container
          .read(textProvider.notifier)
          .updatePosition(const Offset(300, 300), 'note');
      history(container).clearGroupAsAction(ActionGroup.agent);
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'note'));

      history(container).undoAction();
      expect(container.read(agentProvider).map((a) => a.id), ['jett']);
      expect(container.read(actionProvider), isEmpty);
      expect(container.read(textProvider), isEmpty);
    });

    /// [lineup]'s row as a teammate left it, with [notes].
    List<RemoteLineup> withNotes(RemoteLineup lineup, String notes) =>
        [_editedLineup(lineup, (data) => data['notes'] = notes)];

    test(
        'redoing a lineup clear a teammate already undid by deleting '
        'does not resurrect it on the next undo', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      history(container).undoAction();
      expect(container.read(lineUpProvider).origins, hasLength(1));
      await land(container, remote, page); // the teammate deleted it

      history(container).redoAction();
      history(container).undoAction();

      expect(container.read(lineUpProvider).links, isEmpty);
      expect(
        desiredOps(container, page)
            .keys
            .where((key) => key == _lineupKey(page.publicId, 'mine')),
        isEmpty,
      );
    });

    test('a lineup clear redone and undone keeps a teammate notes edit',
        () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      history(container).undoAction();
      await land(container, remote, page,
          lineups: withNotes(mine, 'teammate notes'));
      expect(
          container.read(lineUpProvider).links.single.notes, 'teammate notes');

      history(container).redoAction();
      expect(container.read(lineUpProvider).links, isEmpty);
      await land(container, remote, page);

      history(container).undoAction();
      expect(
          container.read(lineUpProvider).links.single.notes, 'teammate notes');
    });

    test(
        'undoing a lineup clear leaves a lineup a teammate restored, '
        'and redo does not remove it', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      await land(container, remote, page, lineups: withNotes(mine, 'restored'));
      expect(container.read(lineUpProvider).links.single.notes, 'restored');

      history(container).undoAction();
      history(container).redoAction();

      expect(container.read(lineUpProvider).links.single.notes, 'restored');
      expect(
        desiredOps(container, page).values.whereType<LineupDeleteOp>(),
        isEmpty,
      );
    });

    test(
        'redoing a lineup deletion a teammate already made removes nothing '
        'and the next undo does not resurrect it', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      container.read(lineUpProvider.notifier).deleteOrigin('mine');
      history(container).undoAction();
      expect(container.read(lineUpProvider).links, hasLength(1));
      await land(container, remote, page); // the teammate deleted it

      history(container).redoAction();
      expect(container.read(lineUpProvider).links, isEmpty);
      history(container).undoAction();

      expect(container.read(lineUpProvider).links, isEmpty);
      expect(
        desiredOps(container, page)
            .keys
            .where((key) => key == _lineupKey(page.publicId, 'mine')),
        isEmpty,
      );
    });

    test('undoing a weapon change on an agent a teammate deleted does nothing',
        () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .setWeapon('jett', WeaponType.classic);
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'jett'));

      history(container).undoAction();

      expect(container.read(agentProvider), isEmpty);
      expect(history(container).poppedItems, isEmpty);
    });

    test(
        'a weapon change on an agent a teammate deleted leaves history, '
        'so the next undo undoes the change before it', () async {
      final (container, remote, page) =
          await open([jett('jett'), jett('sova')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(200, 200), 'sova');
      container
          .read(agentProvider.notifier)
          .setWeapon('jett', WeaponType.classic);
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'jett'));
      expect(container.read(actionProvider), hasLength(1));

      history(container).undoAction();

      expect(agentOn(container, 'sova').position, const Offset(10, 20));
    });

    test('a lineup weapon change a teammate deleted leaves history', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      container
          .read(lineUpProvider.notifier)
          .setOriginWeapon('mine', WeaponType.classic);
      await land(container, remote, page);

      expect(container.read(actionProvider), isEmpty);
    });

    test('undoing a lineup weapon change a teammate deleted does nothing',
        () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);

      container
          .read(lineUpProvider.notifier)
          .setOriginWeapon('mine', WeaponType.classic);
      await land(container, remote, page);

      history(container).undoAction();

      expect(container.read(lineUpProvider).origins, isEmpty);
      expect(history(container).poppedItems, isEmpty);
    });

    test(
        'undoing a lineup notes edit whose link a teammate deleted does '
        'nothing', () async {
      final mine = _lineup('page-1', 'mine');
      final (container, remote, page) = await open(const [], lineups: [mine]);
      final lineUps = container.read(lineUpProvider.notifier);

      lineUps.updateLink(
        container.read(lineUpProvider).links.single.copyWith(notes: 'mine'),
      );
      lineUps.deleteOrigin('mine');
      history(container).undoAction(); // the deletion
      await land(container, remote, page); // the teammate deleted it

      // Nothing left can change anything: undo never reaches the deletion on
      // the redo stack, so the edit's link cannot come back for it, and
      // redoing the deletion would remove nothing. Both steps go.
      expect(container.read(actionProvider), isEmpty);
      expect(history(container).poppedItems, isEmpty);

      history(container).undoAction();
      expect(container.read(lineUpProvider).links, isEmpty);
    });

    Map<String, dynamic> image(String id) =>
        {'id': id, 'fileExtension': '.png'};

    List<String> linkImages(ProviderContainer container) => [
          for (final image
              in container.read(lineUpProvider).links.single.images)
            image.id,
        ];

    test(
        'redoing an image removal a teammate already made, then undoing, '
        'does not bring the image back', () async {
      final mine = _editedLineup(
        _lineup('page-1', 'mine'),
        (link) => link['images'] = [image('x'), image('y')],
      );
      final (container, remote, page) = await open(const [], lineups: [mine]);
      final link = container.read(lineUpProvider).links.single;

      container.read(lineUpProvider.notifier).updateLink(
            link.copyWith(
              images: link.images.where((i) => i.id != 'x').toList(),
            ),
          );
      history(container).undoAction();
      expect(linkImages(container), ['x', 'y']);
      // A teammate removes x too.
      await land(container, remote, page, lineups: [
        _editedLineup(mine, (link) => link['images'] = [image('y')]),
      ]);
      expect(linkImages(container), ['y']);

      history(container).redoAction();
      expect(linkImages(container), ['y']);
      history(container).undoAction();
      expect(linkImages(container), ['y']);
    });

    test(
        'an edit that removed an image and changed notes replays only the '
        'notes once a teammate removed the image', () async {
      final mine = _editedLineup(
        _lineup('page-1', 'mine'),
        (link) => link['images'] = [image('x'), image('y')],
      );
      final (container, remote, page) = await open(const [], lineups: [mine]);
      final link = container.read(lineUpProvider).links.single;

      container.read(lineUpProvider.notifier).updateLink(
            link.copyWith(
              notes: 'mine',
              images: link.images.where((i) => i.id != 'x').toList(),
            ),
          );
      history(container).undoAction();
      await land(container, remote, page, lineups: [
        _editedLineup(mine, (link) => link['images'] = [image('y')]),
      ]);

      history(container).redoAction();
      expect(container.read(lineUpProvider).links.single.notes, 'mine');
      expect(linkImages(container), ['y']);

      history(container).undoAction();
      expect(
        container.read(lineUpProvider).links.single.notes,
        'remote lineup',
      );
      expect(linkImages(container), ['y']);
    });

    test(
        'an agent a teammate deleted does not swallow the next undo: it '
        'undoes the move made before', () async {
      final (container, remote, page) = await open([jett('sova')]);
      final agents = container.read(agentProvider.notifier);

      agents.addAgent(jett('jett'));
      agents.updatePosition(const Offset(300, 300), 'sova');
      agents.updatePosition(const Offset(200, 200), 'jett');
      await land(container, remote, page,
          teammate: (canvas) => without(canvas, 'jett'));

      history(container).undoAction();

      expect(agentOn(container, 'sova').position, const Offset(10, 20));
    });

    test(
        'a lineup a teammate deleted does not swallow the next undo: it '
        'undoes the move made before', () async {
      final (container, remote, page) = await open([jett('sova')]);
      final lineUps = container.read(lineUpProvider.notifier)..startFresh();
      lineUps.setDraftAgent(PlacedAgent(
        id: 'agent-new',
        type: AgentType.sova,
        position: const Offset(100, 100),
      ));
      lineUps.setDraftAbility(PlacedAbility(
        id: 'ability-new',
        data: AgentData.agents[AgentType.sova]!.abilities[2],
        position: const Offset(300, 300),
      ));
      final placed = lineUps.commitPlacement()!;
      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(300, 300), 'sova');
      lineUps.setOriginWeapon(placed.originId, WeaponType.classic);
      // The teammate deletes the new lineup.
      await land(container, remote, page, lineups: const []);
      expect(container.read(lineUpProvider).links, isEmpty);

      history(container).undoAction();

      expect(agentOn(container, 'sova').position, const Offset(10, 20));
    });

    test(
        'a weapon change a teammate already reverted is skipped: undo '
        'undoes the move made before', () async {
      final (container, remote, page) = await open([
        jett('jett')..weapon = WeaponType.classic,
        jett('sova'),
      ]);
      final agents = container.read(agentProvider.notifier);

      agents.updatePosition(const Offset(300, 300), 'sova');
      agents.setWeapon('jett', WeaponType.vandal);
      // A teammate sets Jett back to the Classic.
      await land(container, remote, page,
          teammate: (canvas) => editing(
                canvas,
                'jett',
                (o) =>
                    (o as PlacedAgent).copyWith()..weapon = WeaponType.classic,
              ));
      expect(agentOn(container, 'jett').weapon, WeaponType.classic);

      history(container).undoAction();

      expect(agentOn(container, 'sova').position, const Offset(10, 20));
      expect(agentOn(container, 'jett').weapon, WeaponType.classic);
    });

    test(
        'a visibility toggle a teammate already reverted is skipped: undo '
        'undoes the move made before', () async {
      final ability = PlacedAbility(
        id: 'mine',
        data: AgentData.agents[AgentType.jett]!.abilities.first,
        position: const Offset(60, 60),
      );
      final (container, remote, page) = await open([ability, jett('sova')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(300, 300), 'sova');
      final abilities = container.read(abilityProvider.notifier);
      abilities.updateVisualState(
        0,
        container
            .read(abilityProvider)
            .single
            .visualState
            .copyWith(showRangeOutline: false),
      );
      // A teammate turns the outline back on.
      await land(container, remote, page,
          teammate: (canvas) => editing(
                canvas,
                'mine',
                (o) => PlacedAbility.fromJson({
                  ...payloadOf(o),
                  'visualState': {
                    ...(o as PlacedAbility).visualState.toJson(),
                    'showRangeOutline': true,
                  },
                }),
              ));
      expect(
        container.read(abilityProvider).single.visualState.showRangeOutline,
        isTrue,
      );

      history(container).undoAction();

      expect(agentOn(container, 'sova').position, const Offset(10, 20));
    });

    test(
        'an edit a teammate partly reverted undoes and redoes only the '
        'fields they left alone', () async {
      const white = 0xFFFFFFFF;
      const red = 0xFFFF0000;
      final (container, remote, page) = await open([
        PlacedCircleAgent(
          id: 'circle',
          type: AgentType.jett,
          position: const Offset(10, 20),
          diameterMeters: 5,
          colorValue: white,
          opacityPercent: 60,
        ),
      ]);
      PlacedCircleAgent circle() =>
          container.read(agentProvider).single as PlacedCircleAgent;

      // One edit changes the diameter and the colour.
      container.read(agentProvider.notifier).updateCircleGeometry(
            id: 'circle',
            diameterMeters: 8,
            colorValue: red,
            opacityPercent: 60,
          );
      // A teammate sets the colour back to white; the diameter stays 8.
      await land(container, remote, page,
          teammate: (canvas) => [
                for (final o in canvas)
                  PlacedAgentNode.fromJson({
                    ...payloadOf(o)..remove('elementType'),
                    'colorValue': white,
                  }),
              ]);
      expect((circle().diameterMeters, circle().colorValue), (8.0, white));

      history(container).undoAction();
      expect((circle().diameterMeters, circle().colorValue), (5.0, white));

      history(container).redoAction();
      expect((circle().diameterMeters, circle().colorValue), (8.0, white));

      history(container).undoAction();
      expect((circle().diameterMeters, circle().colorValue), (5.0, white));
    });

    test('a tiny move is still a move: undo puts the agent back', () async {
      final (container, remote, page) = await open([jett('jett')]);

      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(10.001, 20), 'jett');
      await land(container, remote, page);
      expect(agentOn(container, 'jett').position, const Offset(10.001, 20));

      history(container).undoAction();
      expect(agentOn(container, 'jett').position, const Offset(10, 20));
      expect(
        desiredOps(
            container, page)[EntitySyncKey.element(page.publicId, 'jett')],
        isA<ElementPatchOp>(),
      );

      history(container).redoAction();
      expect(agentOn(container, 'jett').position, const Offset(10.001, 20));
    });

    PlacedAgentNode jettNode(ProviderContainer container) =>
        container.read(agentProvider).singleWhere((a) => a.id == 'jett');

    /// Drops a view cone utility onto Jett as one step, the way the editor
    /// does, after moving Sova.
    Future<(ProviderContainer, _FakeRemoteEditorNotifier, RemotePage)>
        coneOnJettAfterSovaMove() async {
      final opened = await open([jett('jett'), jett('sova'), cone('cone')]);
      final container = opened.$1;
      container
          .read(agentProvider.notifier)
          .updatePosition(const Offset(300, 300), 'sova');
      history(container).performTransaction(
        groups: const [ActionGroup.agent, ActionGroup.utility],
        mutation: () {
          container
              .read(utilityProvider.notifier)
              .removeUtilityAsAction('cone');
          container.read(agentProvider.notifier).convertPlainAgentToViewCone(
                id: 'jett',
                presetType: UtilityType.viewCone90,
                rotation: 0,
                length: 50,
              );
        },
      );
      return opened;
    }

    test(
        'a transaction a teammate partly reverted undoes only what they '
        'left', () async {
      final (container, remote, page) = await coneOnJettAfterSovaMove();
      // A teammate puts the cone back; Jett stays a view cone agent.
      await land(container, remote, page,
          teammate: (canvas) => [...canvas, cone('cone')]);

      history(container).undoAction();

      expect(jettNode(container), isNot(isA<PlacedViewConeAgent>()));
      expect(container.read(utilityProvider).map((u) => u.id), ['cone']);
      // Sova's move is the next step, still to undo.
      expect(agentOn(container, 'sova').position, const Offset(300, 300));
      expect(
        desiredOps(container, page).values.whereType<ElementDeleteOp>(),
        isEmpty,
      );

      history(container).redoAction();
      expect(jettNode(container), isA<PlacedViewConeAgent>());
      expect(container.read(utilityProvider).map((u) => u.id), ['cone']);
    });

    test(
        'a transaction a teammate fully reverted is skipped: undo undoes '
        'the step before', () async {
      final (container, remote, page) = await coneOnJettAfterSovaMove();
      // A teammate puts the cone back and turns Jett back into an agent.
      await land(container, remote, page,
          teammate: (canvas) => [
                for (final o in canvas)
                  if (idOf(o) == 'jett') jett('jett') else o,
                cone('cone'),
              ]);

      history(container).undoAction();

      expect(agentOn(container, 'sova').position, const Offset(10, 20));
      expect(jettNode(container), isNot(isA<PlacedViewConeAgent>()));
      expect(container.read(utilityProvider).map((u) => u.id), ['cone']);
    });

    test('undoing a lineup clear keeps a lineup a teammate added', () async {
      final (container, remote, page) =
          await open(const [], lineups: [_lineup('page-1', 'mine')]);

      history(container).clearGroupAsAction(ActionGroup.lineUp);
      expect(container.read(lineUpProvider).origins, isEmpty);
      await land(container, remote, page,
          lineups: [_lineup(page.publicId, 'theirs')]);

      history(container).undoAction();
      expect(
        container.read(lineUpProvider).origins.map((o) => o.id),
        containsAll(['mine', 'theirs']),
      );
      expect(
        desiredOps(container, page).values.whereType<LineupDeleteOp>(),
        isEmpty,
      );

      history(container).redoAction();
      expect(
        container.read(lineUpProvider).origins.map((o) => o.id),
        ['theirs'],
      );
    });
  });
}
