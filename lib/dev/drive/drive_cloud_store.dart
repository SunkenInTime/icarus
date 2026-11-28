import 'dart:async';
import 'dart:math';

import 'package:flutter/painting.dart' show Offset;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_results.dart';
import 'package:icarus/collab/collab_models.dart'
    show AppliedOpAck, ElementDeleteOp, RemotePageSnapshot;
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/server_rows.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus_library/icarus_library.dart' hide ElementDeleteOp;
import 'package:icarus_library/icarus_library.dart' as queue
    show ElementDeleteOp;
import 'package:uuid/uuid.dart';

CloudSender? _sending(ProviderContainer c) =>
    c.exists(cloudSenderProvider) ? c.read(cloudSenderProvider) : null;

CloudSender _sender(ProviderContainer c) =>
    _sending(c) ??
    (throw StateError('the cloud store does not send in this run'));

LibraryStore _storeOf(ProviderContainer c) => _sender(c).store.store;

String _senderWords(ProviderContainer c) => _viewWords(_sender(c).view);

String _viewWords(SenderView view) => [
      view.run,
      for (final MapEntry(:key, :value) in view.strategies.entries)
        '$key: $value',
    ].join('; ');

Account _signedIn(ProviderContainer c) =>
    switch (c.read(authProvider).user?.id) {
      final String id when id.isNotEmpty => Account(id),
      _ => throw StateError('nobody is signed in'),
    };

Future<String> breakConvexSignIn() async {
  await ConvexClient.instance.setAuthWithRefresh(
    fetchToken: () async => 'a-token-the-server-refuses',
  );
  return 'CLOUDSTORE the Convex client holds a token the server refuses; '
      'it counts itself signed in: ${ConvexClient.instance.isAuthenticated}';
}

Future<String> storeAdd(
  ProviderContainer c,
  String itemId, {
  required String kind,
  required (double, double) at,
}) async {
  final store = _storeOf(c);
  final strategyId = storedCloudStrategy(c);
  final read = await store.readStrategy(strategyId);
  if (read is! Found<StrategyContent> || read.value.pages.isEmpty) {
    throw StateError('the store holds no page of $strategyId: $read');
  }
  final page = read.value.pages.first.publicId;
  final position = Offset(at.$1, at.$2);
  final PageItem item = switch (kind) {
    'agent' => AgentItem(
        PlacedAgent(type: AgentType.jett, position: position, id: itemId),
      ),
    'smoke' => AbilityItem(
        PlacedAbility(
          data: AgentData.agents[AgentType.brimstone]!.abilities[2],
          position: position,
          id: itemId,
          isAlly: true,
        ),
      ),
    _ => throw StateError('no item kind $kind'),
  };
  final payload = switch (item.payload) {
    Read(:final value) => value,
    final other => throw StateError('$itemId has no payload: $other'),
  };
  final op = ElementAddOp(
    opId: const Uuid().v4(),
    elementPublicId: itemId,
    pagePublicId: page,
    payload: payload,
    sortIndex: 1000 + Random().nextInt(1000),
  );
  final saved =
      await store.commitAllAs(_signedIn(c), strategyId, [op], seen: read.value);
  if (saved is! Saved) throw StateError('the store did not take it: $saved');
  return 'CLOUDSTORE committed ${op.opId}: add $kind $itemId to page $page of '
      '$strategyId at (${at.$1}, ${at.$2})';
}

Future<String> storeAddPage(ProviderContainer c) async {
  final store = _storeOf(c);
  final strategyId = storedCloudStrategy(c);
  final read = await store.readStrategy(strategyId);
  if (read is! Found<StrategyContent>) {
    throw StateError('the store could not read $strategyId: $read');
  }
  final op = PageAddOp(
    opId: const Uuid().v4(),
    pagePublicId: const Uuid().v4(),
    sortIndex: read.value.pages.length,
    expectedStrategyRevision:
        (read.value.strategy.toJson()! as Map)['revision']! as int,
  );
  final saved =
      await store.commitAllAs(_signedIn(c), strategyId, [op], seen: read.value);
  if (saved is! Saved) throw StateError('the store did not take it: $saved');
  return 'CLOUDSTORE committed ${op.opId}: add page ${op.pagePublicId} to '
      '$strategyId with no editor open';
}

typedef ExpectedStrategy = ({String id, String name});

typedef LaggingRow = ({String row, String why});

Future<ExpectedStrategy> expectStrategy(
  ProviderContainer c,
  Object which,
  Duration within,
) async {
  final ExpectedStrategy expected;
  switch (which) {
    case true:
      final header =
          c.read(remoteEditorSnapshotProvider).valueOrNull?.shell.header;
      if (header == null) throw StateError('no cloud strategy is open');
      expected = (id: header.publicId, name: header.name);
    case 'held':
      final strategyId = storedCloudStrategy(c);
      final library = _storeOf(c).library;
      expected = (
        id: strategyId,
        name: library is LibraryOpen
            ? library.list.strategies
                .firstWhere((summary) => summary.publicId == strategyId)
                .name
            : strategyId,
      );
    default:
      throw StateError('storeExpect takes true (the open strategy) or "held"');
  }
  final sender = _sender(c);
  final until = DateTime.now().add(within);
  while (sender.adopting(expected.id) ||
      !_storedCloudStrategies(_storeOf(c)).contains(expected.id)) {
    if (DateTime.now().isAfter(until)) {
      throw StateError(
        '${expected.id} was not in the store within ${within.inSeconds} s; '
        'sender ${_senderWords(c)}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return expected;
}

String holdSender(ProviderContainer c) {
  _sender(c).hold('held by the driver');
  return 'CLOUDSTORE sender held by the driver';
}

String releaseSender(ProviderContainer c) {
  _sender(c).release();
  return 'CLOUDSTORE sender released by the driver';
}

Future<String> storeMove(
  ProviderContainer c,
  String itemId,
  (double, double) by, {
  bool startingWith = false,
  bool merge = false,
}) async {
  final store = _storeOf(c);
  for (final strategyId in _storedCloudStrategies(store)) {
    final read = await store.readStrategy(strategyId);
    if (read is! Found<StrategyContent>) continue;
    for (final page in read.value.pages) {
      final content = await store.readPage(strategyId, page.publicId);
      if (content is! Found<PageContent>) continue;
      for (final element in content.value.elements) {
        if (element
            case LiveElement(
              :final publicId,
              :final payload,
              :final revision,
            )
            when startingWith
                ? publicId.startsWith(itemId)
                : publicId == itemId) {
          final data = payload.data.toJson();
          final at = data['position'];
          if (at is! Map) throw StateError('$itemId has no position');
          final position = {
            'dx': (at['dx'] as num).toDouble() + by.$1,
            'dy': (at['dy'] as num).toDouble() + by.$2,
          };
          final op = ElementPatchOp(
            opId: const Uuid().v4(),
            elementPublicId: publicId,
            expectedElementRevision: revision,
            payload: ElementPayload(
              kind: payload.kind,
              payloadVersion: payload.payloadVersion,
              data: {...data, 'position': position},
              unknownFields: payload.unknownFields.toJson(),
            ),
            merge: merge ? FieldMerge(fields: const ['position']) : null,
          );
          final saved = await store.commitAllAs(
            _signedIn(c),
            strategyId,
            [op],
            seen: content.value,
          );
          if (saved case Saved()) {
            return 'CLOUDSTORE committed ${op.opId}: $itemId of $strategyId '
                'to (${position['dx']}, ${position['dy']}) over revision '
                '$revision${merge ? ' as a field merge' : ' as a whole row'}';
          }
          throw StateError('the store did not take the move: $saved');
        }
      }
    }
  }
  throw StateError('the store holds no item $itemId');
}

Future<(String, LiveElement, PageContent)> _storedElement(
  LibraryStore store,
  String itemId,
) async {
  for (final strategyId in _storedCloudStrategies(store)) {
    final read = await store.readStrategy(strategyId);
    if (read is! Found<StrategyContent>) continue;
    for (final page in read.value.pages) {
      final content = await store.readPage(strategyId, page.publicId);
      if (content is! Found<PageContent>) continue;
      for (final element in content.value.elements) {
        if (element case final LiveElement live when live.publicId == itemId) {
          return (strategyId, live, content.value);
        }
      }
    }
  }
  throw StateError('the store holds no item $itemId');
}

Future<String> storeDelete(ProviderContainer c, String itemId) async {
  final store = _storeOf(c);
  final (strategyId, element, seen) = await _storedElement(store, itemId);
  final op = queue.ElementDeleteOp(
    opId: const Uuid().v4(),
    elementPublicId: element.publicId,
    pagePublicId: element.pagePublicId,
    expectedElementRevision: element.revision,
  );
  final saved =
      await store.commitAllAs(_signedIn(c), strategyId, [op], seen: seen);
  if (saved is! Saved) throw StateError('the store did not take it: $saved');
  return 'CLOUDSTORE committed ${op.opId}: delete $itemId of $strategyId over '
      'revision ${element.revision}';
}

Future<String> storeSetField(
  ProviderContainer c,
  String itemId,
  String field,
  Object? value,
) async {
  final store = _storeOf(c);
  final (strategyId, element, seen) = await _storedElement(store, itemId);
  final payload = element.payload;
  final op = ElementPatchOp(
    opId: const Uuid().v4(),
    elementPublicId: element.publicId,
    expectedElementRevision: element.revision,
    payload: ElementPayload(
      kind: payload.kind,
      payloadVersion: payload.payloadVersion,
      data: {...payload.data.toJson(), field: value},
      unknownFields: payload.unknownFields.toJson(),
    ),
    merge: FieldMerge(fields: [field]),
  );
  final saved =
      await store.commitAllAs(_signedIn(c), strategyId, [op], seen: seen);
  if (saved is! Saved) throw StateError('the store did not take it: $saved');
  return 'CLOUDSTORE committed ${op.opId}: $field of $itemId of $strategyId '
      'set to $value as a field merge over revision ${element.revision}';
}

Future<String> waitStoreRefusedLate(
    ProviderContainer c, Duration within) async {
  final store = _storeOf(c);
  final until = DateTime.now().add(within);
  while (true) {
    for (final (strategyId, cloud) in await _cloudQueues(store)) {
      for (final attempt in cloud.queue.attempts.values) {
        if (attempt.outcome
            case AttemptRefusedWhole(refusal: BatchRefusal.uncheckedTooLate)) {
          return 'CLOUDSTORE attempt ${attempt.number} of $strategyId was '
              'refused as arriving too late for its basis: '
              '${attempt.opIds.join(', ')}';
        }
      }
    }
    if (DateTime.now().isAfter(until)) {
      throw StateError(
        'no attempt was refused as late within ${within.inSeconds} s; sender '
        '${_senderWords(c)}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<String> storeDeletePage(ProviderContainer c, int index) async {
  final store = _storeOf(c);
  final strategyId = storedCloudStrategy(c);
  final read = await store.readStrategy(strategyId);
  if (read is! Found<StrategyContent>) {
    throw StateError('the store could not read $strategyId: $read');
  }
  final pages = read.value.pages;
  if (index >= pages.length) {
    throw StateError('$strategyId has ${pages.length} pages, no page $index');
  }
  final page = pages[index].publicId;
  final op = PageDeleteOp(
    opId: const Uuid().v4(),
    pagePublicId: page,
    expectedStrategyRevision:
        (read.value.strategy.toJson()! as Map)['revision']! as int,
  );
  final saved =
      await store.commitAllAs(_signedIn(c), strategyId, [op], seen: read.value);
  if (saved is! Saved) throw StateError('the store did not take it: $saved');
  return 'CLOUDSTORE committed ${op.opId}: delete page $page of $strategyId '
      'with no editor open';
}

Future<String> storeDiscardUnreadable(ProviderContainer c) async {
  final strategyId = storedCloudStrategy(c);
  final discarded = await _storeOf(c).discardUnreadableQueue(
    _signedIn(c),
    strategyId,
    const DiscardsUnsentWork(),
  );
  if (discarded is! Saved) {
    throw StateError('the store did not discard the queue: $discarded');
  }
  return 'CLOUDSTORE discarded the unreadable queue of $strategyId';
}

Future<String> setMemberRole(ProviderContainer c, String role) async {
  final strategyId =
      c.read(remoteEditorSnapshotProvider).valueOrNull?.shell.header.publicId;
  if (strategyId == null) throw StateError('no cloud strategy is open');
  final repository = c.read(convexStrategyRepositoryProvider);
  final members = (await repository.listShareMembers(
    targetType: 'strategy',
    targetPublicId: strategyId,
  ))
      .members;
  if (members.length != 1) {
    throw StateError('$strategyId has ${members.length} members, not one');
  }
  await repository.setShareMemberRole(
    targetType: 'strategy',
    targetPublicId: strategyId,
    memberId: members.single.memberId,
    role: role,
  );
  return 'CLOUDSTORE set the teammate\'s role on $strategyId to $role';
}

Future<List<(String, CloudStrategy)>> _cloudQueues(LibraryStore store) async =>
    (await _cloudQueuesAndRefusals(store)).queues;

Future<({List<(String, CloudStrategy)> queues, List<String> refused})>
    _cloudQueuesAndRefusals(LibraryStore store) async {
  final queues = <(String, CloudStrategy)>[];
  for (final strategyId in _storedCloudStrategies(store)) {
    if (store.refusedStrategies.containsKey(strategyId)) continue;
    switch (await store.readStrategy(strategyId)) {
      case Found(value: StrategyContent(sync: final CloudStrategy cloud)):
        queues.add((strategyId, cloud));
      case InUnreadableStrategy(
          listing: UnreadableStrategyListing(refused: StoredRowsDisagree()),
        ):
        break;
      case final other:
        throw StateError('the queue of $strategyId could not be read: $other');
    }
  }
  final refused = store.refusedStrategies;
  return (
    queues: [
      for (final queue in queues)
        if (!refused.containsKey(queue.$1)) queue,
    ],
    refused: [
      for (final MapEntry(key: strategyId, value: refusal) in refused.entries)
        '$strategyId is refused by the store, so its work is not sent: '
            '${refusal.reason}',
    ],
  );
}

Future<String> waitStoreSent(
  ProviderContainer c,
  Duration within, {
  bool landedMayWait = false,
}) =>
    waitStoreSentIn(
      _storeOf(c),
      within,
      landedMayWait: landedMayWait,
      senderWords: () => _senderWords(c),
    );

Future<String> waitStoreSentIn(
  LibraryStore store,
  Duration within, {
  bool landedMayWait = false,
  required String Function() senderWords,
}) async {
  final until = DateTime.now().add(within);
  while (true) {
    final (:queues, :refused) = await _cloudQueuesAndRefusals(store);
    if (refused.isNotEmpty) throw StateError(refused.join('; '));
    if (queues.isEmpty) {
      throw StateError('the store lists no cloud queue to wait on');
    }
    final left = [
      for (final (strategyId, cloud) in queues)
        if (cloud.queue.entries.isNotEmpty ||
            (!landedMayWait && cloud.queue.landed.isNotEmpty))
          '$strategyId: ${cloud.queue.entries.length} entries, '
              '${cloud.queue.landed.length} landed',
    ];
    if (left.isEmpty) {
      final landed = [
        for (final (strategyId, cloud) in queues)
          if (cloud.queue.landed.isNotEmpty)
            '${cloud.queue.landed.length} landed ops of $strategyId',
      ];
      return 'CLOUDSTORE every queue is empty and '
          '${landed.isEmpty ? 'no landed work waits for a result' : '${landed.join(', ')} wait for a result'}'
          '; sender ${senderWords()}';
    }
    if (DateTime.now().isAfter(until)) {
      throw StateError(
        'work left after ${within.inSeconds} s: ${left.join('; ')}; sender '
        '${senderWords()}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<List<String>> storeQueueRecords(ProviderContainer c) async => [
      for (final (strategyId, cloud) in await _cloudQueues(_storeOf(c)))
        'CLOUDSTORE record of $strategyId: written in strategy life '
            '${cloud.queue.shown.strategy?.life}; queued '
            '[${[
          for (final entry in cloud.queue.entries)
            if (entry is PendingOp)
              '${entry.id} ${entry.op.type.wireName} life '
                  '${expectedLifeOf(entry)} strategy life ${entry.strategyLife} '
                  '${cloud.views[entry.id]?.state}',
        ].join('; ')}]; set aside ${switch (cloud.queue.strategy.setAside) {
          SetAside(:final generations) => [
              for (final generation in generations)
                '$generation: '
                    '${generation.entries.map((entry) => entry.id).join(', ')}',
            ].join('; '),
          NothingSetAside() => 'nothing',
        }}; tally ${Tally.of(cloud.queue, DateTime.now()).toJson()}',
    ];

Future<List<String>> storeNeedsYou(ProviderContainer c) async {
  final lines = <String>[];
  for (final (strategyId, cloud) in await _cloudQueues(_storeOf(c))) {
    for (final entry in cloud.queue.entries) {
      if (cloud.views[entry.id]?.state case NeedsUser(:final reason)) {
        lines.add(
          'CLOUDSTORE needs you: ${entry.id} of $strategyId, ${reason.runtimeType} '
          '$reason',
        );
      }
    }
  }
  if (lines.isEmpty) throw StateError('no entry needs the user');
  return lines;
}

Future<String> storeUseCloud(ProviderContainer c, String itemId) async {
  final store = _storeOf(c);
  final strategyId = await _strategyHolding(store, itemId);
  final chosen = await useCloudAs(store, _signedIn(c), strategyId);
  return 'CLOUDSTORE used the cloud\'s version for ${chosen.join(', ')} of '
      '$strategyId';
}

Future<String> _strategyHolding(LibraryStore store, String itemId) async {
  for (final strategyId in _storedCloudStrategies(store)) {
    final read = await store.readStrategy(strategyId);
    if (read is! Found<StrategyContent>) continue;
    for (final page in read.value.pages) {
      final content = await store.readPage(strategyId, page.publicId);
      if (content is! Found<PageContent>) continue;
      if (content.value.elements.any(
        (element) => element is LiveElement && element.publicId == itemId,
      )) {
        return strategyId;
      }
    }
  }
  throw StateError('the store holds no item $itemId');
}

Future<List<String>> useCloudAs(
  LibraryStore store,
  Account signedIn,
  String strategyId,
) async {
  final CloudStrategy cloud;
  switch (await store.readStrategy(strategyId)) {
    case Found(value: StrategyContent(sync: final CloudStrategy found)):
      cloud = found;
    case final other:
      throw StateError('the queue of $strategyId could not be read: $other');
  }
  final chosen = [
    for (final entry in cloud.queue.entries)
      if (cloud.views[entry.id]?.state is NeedsUser) entry.id,
  ];
  if (chosen.isEmpty)
    throw StateError('no entry of $strategyId needs the user');
  for (final opId in chosen) {
    switch (await store.record(signedIn, strategyId, [UserUsedCloud(opId)])) {
      case Saved(:final value):
        for (final outcome in value.outcomes) {
          if (outcome case ReportNotApplicable(:final why)) {
            throw StateError('use cloud for $opId was not applied: $why');
          }
        }
      case NothingToSave():
        throw StateError('use cloud for $opId changed nothing');
      case Refused(:final reason):
        throw StateError('use cloud for $opId was refused: $reason');
      case NotSaved(:final failure):
        throw StateError(
          'use cloud for $opId was not written: '
          '${storageFailureWords(failure, StoreStep.refusedSave)}',
        );
      case SaveInDoubt(:final failure):
        throw StateError(
          'use cloud for $opId may not have been written: '
          '${storageFailureWords(failure, StoreStep.saveInDoubt)}',
        );
    }
  }
  return chosen;
}

Future<String> waitStoreHeld(
  ProviderContainer c,
  Duration within, {
  bool bySender = false,
}) async {
  final strategyId = storedCloudStrategy(c);
  final until = DateTime.now().add(within);
  while (true) {
    final cloud = switch (await _storeOf(c).readStrategy(strategyId)) {
      Found(value: StrategyContent(sync: final CloudStrategy cloud)) => cloud,
      final other => throw StateError('$strategyId could not be read: $other'),
    };
    final viewer = _sender(c).accessRung(strategyId);
    if (standingOf(cloud.queue) == Standing.editAccessLost &&
        cloud.queue.entries.isNotEmpty &&
        viewer != null &&
        viewer.cannot == null &&
        (!bySender || viewer.count > 0)) {
      return 'CLOUDSTORE $strategyId is held for lost edit access with '
          '${cloud.queue.entries.length} entries unsent, and its page list '
          'said this account can only view it'
          '${bySender ? ' (the sender\'s own read, ${viewer.count} so far)' : ''}';
    }
    if (DateTime.now().isAfter(until)) {
      throw StateError(
        '$strategyId was not held for lost edit access with a viewer\'s '
        '${bySender ? 'answer from the sender\'s own read ' : 'answer '}within ${within.inSeconds} s: standing '
        '${standingOf(cloud.queue).name}, ${cloud.queue.entries.length} '
        'entries, viewer answer $viewer; sender ${_senderWords(c)}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<String> waitStoreReading(ProviderContainer c, Duration within) async {
  final sender = _sender(c);
  final before = sender.reads;
  final until = DateTime.now().add(within);
  while (true) {
    if (sender.reads > before) {
      if (sender.reading case final why?) {
        return 'CLOUDSTORE the sender had a read in flight when this step '
            'looked: $why; it may be answered or lost before the network '
            'returns; sender ${_senderWords(c)}';
      }
    }
    if (DateTime.now().isAfter(until)) {
      throw StateError(
        'the sender had no read in flight that it began within '
        '${within.inSeconds} s; ${sender.reads - before} began and ended; '
        'sender ${_senderWords(c)}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

List<String> storeSessionOpenings(
  ProviderContainer c, {
  required bool stampExpected,
}) =>
    [
      reconnectSessionOpening(
        _sender(c).store.reports,
        storedCloudStrategy(c),
        stampExpected: stampExpected,
      ),
    ];

({int cut, int session}) _cutIn(List<SenderReport> reports, String strategyId) {
  final binds = [
    for (final (index, report) in reports.indexed)
      if (report
          case SessionOpenedFor(
            strategyId: final id,
            :final session,
            :final stamp,
          ) when id == strategyId)
        (index: index, session: session, connection: stamp.connection),
  ];
  final connections = {for (final bind in binds) bind.connection};
  if (binds.isEmpty || connections.length != 2) {
    throw StateError(
      'the sender bound $strategyId on ${connections.length} connections, '
      'not two, so the cut cannot be told apart',
    );
  }
  final first = binds.first.connection;
  final at = binds.indexWhere((bind) => bind.connection != first);
  return (cut: binds[at - 1].index, session: binds[at].session);
}

String reconnectSessionOpening(
  List<SenderReport> reports,
  String strategyId, {
  required bool stampExpected,
}) {
  final (:cut, :session) = _cutIn(reports, strategyId);
  final opened = [
    for (final report in reports.sublist(cut + 1))
      if (report
          case EventsWritten(
            strategyId: final id,
            :final events,
            :final effects
          ) when id == strategyId)
        for (final opening in effects.whereType<SessionOpened>())
          (session: opening.session, by: _openedBy(events)),
  ];
  String words(({int session, String? by}) opening) =>
      'session ${opening.session} by ${opening.by ?? 'a result\'s stamp'}';
  if (opened case [final only] when only.session == session) {
    if (stampExpected && only.by != null) {
      throw StateError(
        'the reconnect after the cut bound $strategyId to ${words(only)}, '
        'not by a result\'s stamp',
      );
    }
    return 'CLOUDSTORE the reconnect after the cut bound $strategyId to '
        '${words(only)}, the one session opened from the cut to the end of '
        'the run';
  }
  throw StateError(
    'the reconnect after the cut bound session $session of $strategyId, and '
    'from the cut to the end of the run the store opened '
    '${opened.isEmpty ? 'no session' : opened.map(words).join(', ')}, not '
    'that session alone',
  );
}

String storeResultsDropped(ProviderContainer c) {
  final strategyId = storedCloudStrategy(c);
  final dropped = [
    for (final report in _sender(c).store.reports)
      if (report case StoredResultsDroppedReport(:final dropped)
          when report.strategyId == strategyId)
        dropped,
  ];
  if (dropped case [final only]) {
    return 'CLOUDSTORE the sender reported once that the stored results of '
        '$strategyId were dropped: ${only.group}: ${only.problem}';
  }
  throw StateError(
    'the sender reported ${dropped.length} drops of the stored results of '
    '$strategyId, not one',
  );
}

List<String> storeAnswerLostAndResent(ProviderContainer c) => [
      lostAnswerResent(_sender(c).store.reports, storedCloudStrategy(c)),
    ];

sealed class _Resend {
  const _Resend(this.words);

  final String words;
}

final class _AnsweredAsApplied extends _Resend {
  const _AnsweredAsApplied(super.words);
}

final class _NeverReceived extends _Resend {
  const _NeverReceived(super.words);
}

final class _ResendWrong extends _Resend {
  const _ResendWrong(super.words);
}

String lostAnswerResent(List<SenderReport> reports, String strategyId) {
  final sent = <int, ClaimedBatch>{
    for (final report in reports)
      if (report case BatchSentAs(strategyId: final id, :final batch)
          when id == strategyId)
        batch.attempt: batch,
  };
  final writes = [
    for (final report in reports)
      if (report case EventsWritten(strategyId: final id) when id == strategyId)
        report,
  ];
  final (:cut, session: _) = _cutIn(reports, strategyId);
  final lost = <int, String>{};
  for (final write in [
    for (final report in reports.sublist(cut + 1))
      if (report case EventsWritten(strategyId: final id) when id == strategyId)
        report,
  ]) {
    final admitted = {
      for (final effect in write.effects)
        if (effect case AnswerAdmitted(:final attempt)) attempt,
    };
    for (final event in write.events) {
      switch (event) {
        case TransportFailed(:final attempt, :final failure)
            when sent.containsKey(attempt):
          lost[attempt] ??= 'no answer came (${failure.name})';
        case OpAnswered(:final attempt, :final point) ||
                BatchRefused(:final attempt, :final point) ||
                BatchAccountMismatch(:final attempt, :final point)
            when sent.containsKey(attempt) && !admitted.contains(attempt):
          lost[attempt] ??= 'its answer came on connection '
              '${point.connection}, which had ended';
        case _:
          break;
      }
    }
  }
  if (lost.isEmpty) {
    throw StateError(
      'did not reach the case: none of the ${sent.length} batches sent for '
      '$strategyId had its answer closed as lost after the cut',
    );
  }
  OpAnswer? admittedAnswer(int attempt, String opId) {
    for (final write in writes) {
      if (!write.effects.contains(AnswerAdmitted(attempt, opId: opId))) {
        continue;
      }
      for (final event in write.events) {
        if (event case OpAnswered(attempt: final at, :final answer)
            when at == attempt && answer.opId == opId) {
          return answer;
        }
      }
    }
    return null;
  }

  final resends = <_Resend>[];
  for (final MapEntry(key: attempt, value: how) in lost.entries) {
    final ops = {for (final op in sent[attempt]!.ops) op.opId};
    final again = [
      for (final later in sent.values)
        if (later.attempt > attempt)
          for (final op in later.ops)
            if (ops.contains(op.opId)) (attempt: later.attempt, opId: op.opId),
    ];
    if (again.isEmpty) {
      resends.add(
        _ResendWrong(
          'attempt $attempt was closed as lost ($how), and none of its ops '
          'was sent again',
        ),
      );
    }
    for (final (attempt: resent, :opId) in again) {
      final first = 'attempt $attempt was closed as lost ($how); $opId was '
          'sent again in attempt $resent';
      resends.add(switch (admittedAnswer(resent, opId)) {
        NoopAnswer(replay: NoopReplay.appliedWhenFirstReceived) =>
          _AnsweredAsApplied(
            '$first, and the server answered it as applied when first '
            'received',
          ),
        AppliedAnswer() => _NeverReceived(
            '$first, and that send applied it: the server never received '
            'attempt $attempt',
          ),
        null => _ResendWrong('$first, and no answer to it was admitted'),
        final other => _ResendWrong(
            '$first, and the server answered ${other.runtimeType}',
          ),
      });
    }
  }
  if (resends.whereType<_AnsweredAsApplied>().firstOrNull case final done?) {
    return 'CLOUDSTORE ${done.words}';
  }
  final words = resends.map((resend) => resend.words).join('; ');
  if (resends.every((resend) => resend is _NeverReceived)) {
    throw StateError('did not reach the case: $words');
  }
  throw StateError(words);
}

String? _openedBy(List<QueueEvent> events) => switch (events
        .where(
          (event) =>
              event is ConnectionReturned ||
              event is AppRestarted ||
              event is AccountChanged,
        )
        .firstOrNull) {
      ConnectionReturned() => 'the reconnect event',
      AppRestarted() => 'the app start',
      AccountChanged() => 'an account change',
      _ => null,
    };

Future<List<String>> storeSyncStates(ProviderContainer c) async {
  final signedIn = switch (c.read(authProvider).user?.id) {
    final String id when id.isNotEmpty => SignedInAs(Account(id)),
    _ => const SignedOut(),
  };
  final library = _storeOf(c).library;
  if (library is! LibraryOpen) throw StateError('the store is shut');
  return [
    for (final summary in library.list.strategies)
      if (summary.sync case KeptInCloud(:final owner, :final tally))
        'CLOUDSTORE sync of ${summary.publicId} for $signedIn: '
            '${syncStateOf(owner, tally, network: Network.online, signedIn: signedIn)}, '
            'the work of $owner; run hold ${_sender(c).runHold ?? 'none'}; '
            'read hold ${_sender(c).cannotRead(summary.publicId) ?? 'none'}; '
            'could not resolve '
            '${_sender(c).couldNotResolve(summary.publicId) ?? 'nothing'}; '
            'inputs ${_sender(c).inputs}; '
            'sender ${_senderWords(c)}',
  ];
}

List<String> _storedCloudStrategies(LibraryStore store) {
  final library = store.library;
  if (library is! LibraryOpen) throw StateError('the store is shut');
  return [
    for (final summary in library.list.strategies)
      if (summary.sync is KeptInCloud || summary.sync is CloudUnverified)
        summary.publicId,
  ];
}

String storedCloudStrategy(ProviderContainer c) {
  final cloud = _storedCloudStrategies(_storeOf(c));
  if (cloud.length != 1) {
    throw StateError('the store holds ${cloud.length} cloud strategies');
  }
  return cloud.single;
}

Future<String> pageListRefusal(
  ProviderContainer c,
  String accountSubject,
) async {
  final strategyId =
      c.read(remoteEditorSnapshotProvider).valueOrNull?.shell.header.publicId;
  if (strategyId == null) throw StateError('no cloud strategy is open');
  final signedIn = c.read(authProvider).user?.id;
  if (signedIn == null || signedIn == accountSubject) {
    throw StateError(
      'a refusal needs a sign-in other than $accountSubject, and this one '
      'is $signedIn',
    );
  }
  try {
    await c
        .read(convexStrategyRepositoryProvider)
        .watchPageList(strategyId, accountSubject: accountSubject)
        .first
        .timeout(const Duration(seconds: 20));
  } catch (error) {
    if (!isAccountMismatchError(error)) rethrow;
    return 'CLOUDSTORE a page list read naming $accountSubject, signed in as '
        '$signedIn, was refused: $error';
  }
  throw StateError(
    'a page list read naming $accountSubject was answered while signed in '
    'as $signedIn',
  );
}

Future<String> batchRefusal(
  ProviderContainer c,
  String accountSubject, {
  required bool readsAccountMismatch,
}) async {
  final strategyId =
      c.read(remoteEditorSnapshotProvider).valueOrNull?.shell.header.publicId;
  if (strategyId == null) throw StateError('no cloud strategy is open');
  final signedIn = c.read(authProvider).user?.id;
  if (signedIn == null || signedIn == accountSubject) {
    throw StateError(
      'a refusal needs a sign-in other than $accountSubject, and this one '
      'is $signedIn',
    );
  }
  final expected = readsAccountMismatch
      ? isAccountMismatchError
      : isTypedConvexForbiddenError;
  try {
    await c
        .read(convexStrategyRepositoryProvider)
        .sendEmptyBatch(
          strategyPublicId: strategyId,
          accountSubject: accountSubject,
          readsAccountMismatch: readsAccountMismatch,
        )
        .timeout(const Duration(seconds: 20));
  } catch (error) {
    if (!expected(error)) rethrow;
    return 'CLOUDSTORE a batch naming $accountSubject, signed in as '
        '$signedIn, ${readsAccountMismatch ? 'reading' : 'not reading'} '
        'the mismatch, was refused: $error';
  }
  throw StateError(
    'a batch naming $accountSubject was answered while signed in as '
    '$signedIn',
  );
}

Future<String> uncheckedDelete(
  ProviderContainer c,
  String elementId, {
  required int basisAgeMs,
  required bool expectRefused,
}) async {
  final page = c.read(remoteEditorSnapshotProvider).valueOrNull?.activePage;
  if (page == null) throw StateError('no cloud page is open');
  final row = page.elements.where((row) => row.publicId == elementId).single;
  final repository = c.read(convexStrategyRepositoryProvider);
  final strategyId = row.strategyPublicId;
  final basis = (await repository.sendWithLiveBasis(
    strategyPublicId: strategyId,
    clientId: 'live-basis',
    ops: const [],
  ))
      .serverTime;
  final delete = ElementDeleteOp(
    opId: 'unchecked-delete-$elementId',
    elementPublicId: elementId,
    pagePublicId: row.pagePublicId,
    expectedElementRevision: row.revision,
    lastWriterWins: true,
  );
  final liveBasis = basis - basisAgeMs;
  final described = 'an unchecked delete of $elementId at revision '
      '${row.revision} with a live basis $basisAgeMs ms before the server '
      'time $basis';
  try {
    final sent = await repository
        .sendWithLiveBasis(
          strategyPublicId: strategyId,
          clientId: 'live-basis',
          ops: [delete],
          liveBasis: liveBasis,
        )
        .timeout(const Duration(seconds: 20));
    final ack = sent.acks.single;
    if (expectRefused || ack is! AppliedOpAck) {
      throw StateError('$described was answered $ack');
    }
    return 'CLOUDSTORE $described was applied at revision '
        '${ack.revision}; server time ${sent.serverTime}';
  } catch (error) {
    if (!expectRefused || !isUncheckedOutsideWindowError(error)) rethrow;
    return 'CLOUDSTORE $described was refused: $error';
  }
}

final class CloudStoreLine {
  const CloudStoreLine(this.text, {required this.problem});

  final String text;
  final bool problem;
}

final class CloudStoreLog {
  CloudStoreLog({this.finalWait = const Duration(seconds: 30)});

  final Duration finalWait;

  StreamSubscription<SenderView>? _senderViews;
  final _senderLines = <CloudStoreLine>[];
  int _senderReportsRead = 0;
  final expected = <ExpectedStrategy>[];
  final lagging = <LaggingRow>[];

  void _watchSender(ProviderContainer c) {
    if (_senderViews != null) return;
    final sender = _sending(c);
    if (sender == null) return;
    _senderLines.add(
      CloudStoreLine(
        'CLOUDSTORE sender: ${_viewWords(sender.view)}',
        problem: false,
      ),
    );
    _senderViews = sender.views.listen(
      (next) => _senderLines.add(
        CloudStoreLine(
          'CLOUDSTORE sender at ${_clockTime(DateTime.now())}: '
          '${_viewWords(next)}',
          problem: next.run.startsWith('ended'),
        ),
      ),
    );
  }

  bool isOn(ProviderContainer c) => c.exists(cloudSenderProvider);

  List<CloudStoreLine> drain(ProviderContainer c) {
    if (!isOn(c)) return const [];
    return _senderDrain(c);
  }

  List<CloudStoreLine> _senderDrain(ProviderContainer c) {
    _watchSender(c);
    final sender = _sending(c);
    final senderReports = <SenderReport>[];
    if (sender != null) {
      final SenderStore(:reports, :reportsDropped) = sender.store;
      senderReports.addAll(
        reports.skip(max(0, _senderReportsRead - reportsDropped)),
      );
      _senderReportsRead = reportsDropped + reports.length;
    }
    final lines = [
      ..._senderLines,
      for (final report in senderReports)
        if (_senderReportLine(report) case final line?) line,
    ];
    _senderLines.clear();
    return lines;
  }

  Future<List<CloudStoreLine>> end(
    ProviderContainer c, {
    required DateTime lastStep,
  }) async {
    if (!isOn(c)) return const [];
    return _senderEnd(c, lastStep);
  }

  Future<List<CloudStoreLine>> _senderEnd(
    ProviderContainer c,
    DateTime lastStep,
  ) async {
    final sender = _sending(c);
    if (sender == null) {
      return [
        CloudStoreLine(
          'CLOUDSTORE the sender never started: '
          '${switch (c.read(cloudSenderProvider.notifier)) {
            CloudSenderNotifier(opened: final opened?) => _opened(opened),
            CloudSenderNotifier(openingThrew: final error?) =>
              'opening the store threw: $error',
            _ => 'the store had not opened',
          }}',
          problem: true,
        ),
      ];
    }
    final deadline = lastStep.add(finalWait);
    final stopping = await _senderStopped(c, deadline);
    if (sender.busy) {
      return [
        ..._senderDrain(c),
        ...stopping,
        const CloudStoreLine(
          'CLOUDSTORE the store was not compared with the server: the sender '
          'was still in a step, so the store could still change',
          problem: true,
        ),
      ];
    }
    final left = await _workLeft(sender.store.store);
    final asLeft = await _compareWithServer(
      c,
      sender.store.store,
      when: 'as the run left the store',
      expected: expected,
      lagging: lagging,
    );
    final reads = <String, int>{};
    for (final report in sender.store.reports) {
      if (report case ReadRecorded(:final why)) {
        reads[why] = (reads[why] ?? 0) + 1;
      }
    }
    return [
      ..._senderDrain(c),
      ...stopping,
      ...left,
      ...asLeft,
      CloudStoreLine(
        'CLOUDSTORE the sender made ${sender.reads} named reads, '
        '${reads.values.fold(0, (a, b) => a + b)} recorded'
        '${[
          for (final MapEntry(:key, :value) in reads.entries)
            ', $value because $key'
        ].join()}',
        problem: false,
      ),
    ];
  }

  Future<List<CloudStoreLine>> _senderStopped(
    ProviderContainer c,
    DateTime deadline,
  ) async {
    final sender = _sending(c);
    if (sender == null) return const [];
    sender.hold('the run ended');
    while (sender.busy) {
      if (DateTime.now().isAfter(deadline)) {
        return [
          CloudStoreLine(
            'CLOUDSTORE the sender had not finished by the end: '
            '${_viewWords(sender.view)}',
            problem: true,
          ),
        ];
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return [
      if (sender.ended case final why?)
        CloudStoreLine('CLOUDSTORE the sender ended: $why', problem: true),
    ];
  }

  Future<List<CloudStoreLine>> _workLeft(LibraryStore store) async => [
        for (final (strategyId, cloud) in await _cloudQueues(store)) ...[
          for (final entry in cloud.queue.entries)
            CloudStoreLine(
              'CLOUDSTORE work left in the queue of $strategyId: ${entry.id} '
              '${cloud.views[entry.id]?.state}',
              problem: true,
            ),
          if (cloud.queue.landed.isNotEmpty)
            CloudStoreLine(
              'CLOUDSTORE ${cloud.queue.landed.length} landed ops of '
              '$strategyId wait for a result to show them',
              problem: false,
            ),
        ],
      ];

  List<CloudStoreLine> closeFailed(ProviderContainer c, Object error) {
    if (!isOn(c)) return const [];
    return [
      CloudStoreLine(
        'CLOUDSTORE closing the store failed: $error',
        problem: true,
      ),
    ];
  }

  Future<List<CloudStoreLine>> readBack(ProviderContainer c) async {
    if (!isOn(c)) return const [];
    return _namedReadBack(c, expected, lagging);
  }
}

Future<List<CloudStoreLine>> _namedReadBack(
  ProviderContainer c,
  List<ExpectedStrategy> expected,
  List<LaggingRow> lagging,
) async {
  final sender = _sending(c);
  final opened = c.read(cloudSenderProvider.notifier).opened;
  if (sender == null || opened is! LibraryStoreReady) return const [];
  if (c.read(libraryStoreProvider) is! LibraryStoreClosed) {
    return const [
      CloudStoreLine(
        'CLOUDSTORE read back skipped: the store was not closed',
        problem: true,
      ),
    ];
  }
  switch (await openLibraryStore(opened.file, build: sender.build)) {
    case LibraryStoreReady(:final store, :final closeEngine):
      try {
        return await _compareWithServer(
          c,
          store,
          when: 'after reopening the store',
          expected: expected,
          lagging: lagging,
        );
      } finally {
        await store.close();
        await closeEngine();
      }
    case final other:
      return [
        CloudStoreLine(
          'CLOUDSTORE read back could not reopen the store: ${_opened(other)}',
          problem: true,
        ),
      ];
  }
}

Future<List<CloudStoreLine>> _compareWithServer(
  ProviderContainer c,
  LibraryStore store, {
  required String when,
  required List<ExpectedStrategy> expected,
  required List<LaggingRow> lagging,
}) async {
  final signedIn = switch (c.read(authProvider).user?.id) {
    final String id when id.isNotEmpty => Account(id),
    _ => null,
  };
  if (signedIn == null) {
    return [
      CloudStoreLine(
        'CLOUDSTORE compared $when: nobody is signed in at the end, so the '
        'server\'s copy cannot be read as the store\'s account and the store '
        'was not compared',
        problem: true,
      ),
    ];
  }
  final repository = c.read(convexStrategyRepositoryProvider);
  final held = await compareStoreWithServer(
    store,
    signedIn: signedIn,
    server: (
      pageList: (strategyId) => repository.readPageListAs(
            strategyId,
            accountSubject: signedIn.subject,
          ),
      page: (strategyId, pageId) => repository.readPageAs(
            strategyPublicId: strategyId,
            pagePublicId: pageId,
            accountSubject: signedIn.subject,
          ),
    ),
  );
  return comparisonLines(
    when: when,
    readAs: signedIn.subject,
    held: held,
    expected: expected,
    lagging: lagging,
  );
}

typedef ServerReads = ({
  Future<RemotePageList> Function(String strategyId) pageList,
  Future<RemotePageSnapshot> Function(String strategyId, String pageId) page,
});

Future<List<ServerComparison>> compareStoreWithServer(
  LibraryStore store, {
  required Account signedIn,
  required ServerReads server,
}) async {
  final library = store.library;
  final summaries = library is LibraryOpen
      ? library.list.strategies
      : const <StrategySummary>[];
  final held = <ServerComparison>[];
  for (final summary in summaries) {
    final owner = switch (summary.sync) {
      KeptInCloud(owner: OwnedBy(:final account)) ||
      CloudUnverified(owner: OwnedBy(:final account)) =>
        account,
      _ => null,
    };
    if (owner == null) continue;
    held.add(
      (
        strategyId: summary.publicId,
        name: summary.name,
        verdict: owner == signedIn
            ? await _againstServer(store, summary.publicId, signedIn, server)
            : NotCompared(
                'the work of ${owner.subject} while signed in as '
                '${signedIn.subject}',
              ),
      ),
    );
  }
  return held;
}

Future<StoreVerdict> _againstServer(
  LibraryStore store,
  String strategyId,
  Account signedIn,
  ServerReads server,
) async {
  final rows = ServerRows();
  final unjudged = <String>[];
  final RemotePageList list;
  try {
    list = await server.pageList(strategyId);
    switch (pageListRead(list)) {
      case RowsRead(:final value):
        rows.header(value);
      case RowsUnreadable(:final problem):
        return Compared(
          pages: list.pages.length,
          unjudged: [
            'the page list: the server rows could not be read: $problem'
          ],
          differences: null,
        );
    }
    for (final page in list.pages) {
      final pageId = page.page.publicId;
      switch (pageRead(await server.page(strategyId, pageId), appCanRead)) {
        case RowsRead(:final value):
          rows.page(value);
        case RowsUnreadable(:final problem):
          unjudged
              .add('page $pageId: the server rows could not be read: $problem');
      }
    }
  } catch (error) {
    return NotCompared('could not read the server\'s copy: $error');
  }
  return Compared(
    pages: list.pages.length,
    unjudged: unjudged,
    differences: await differencesFromServer(
      store,
      strategyId,
      rows,
      account: signedIn,
      pages: null,
    ),
  );
}

sealed class StoreVerdict {
  const StoreVerdict();
}

final class Compared extends StoreVerdict {
  const Compared({
    required this.pages,
    required this.unjudged,
    required this.differences,
  });

  final int pages;
  final List<String> unjudged;
  final List<String>? differences;
}

final class NotCompared extends StoreVerdict {
  const NotCompared(this.why);

  final String why;
}

typedef ServerComparison = ({
  String strategyId,
  String name,
  StoreVerdict verdict,
});

final _olderRevision = RegExp(
  r'^page \S+: item (\S+): the store holds (?:live|deleted) at revision '
  r'(\d+), the server sent (?:live|deleted) at revision (\d+)$',
);

LaggingRow? excusedBy(String difference, List<LaggingRow> lagging) {
  final match = _olderRevision.firstMatch(difference);
  if (match == null) return null;
  final [row!, held!, sent!] = [match[1], match[2], match[3]];
  if (int.parse(held) >= int.parse(sent)) return null;
  return lagging.where((lag) => lag.row == row).firstOrNull;
}

List<CloudStoreLine> comparisonLines({
  required String when,
  required String readAs,
  required List<ServerComparison> held,
  required List<ExpectedStrategy> expected,
  required List<LaggingRow> lagging,
}) {
  bool names(ExpectedStrategy wanted, ServerComparison comparison) =>
      comparison.strategyId == wanted.id;
  return [
    if (expected.isEmpty)
      CloudStoreLine(
        'CLOUDSTORE compared $when: the script names no strategy it expects '
        'the store to hold',
        problem: true,
      ),
    for (final wanted in expected)
      if (!held.any((comparison) =>
          names(wanted, comparison) && comparison.verdict is Compared))
        CloudStoreLine(
          'CLOUDSTORE compared $when: ${wanted.id} "${wanted.name}" got no '
          'verdict: '
          '${switch (held.where((comparison) => names(wanted, comparison)).firstOrNull) {
            (verdict: NotCompared(:final why), strategyId: _, name: _) => why,
            _ => 'the store does not hold it',
          }}',
          problem: true,
        ),
    for (final (:strategyId, :name, :verdict) in held)
      ...switch (verdict) {
        NotCompared(:final why) => [
            CloudStoreLine(
              'CLOUDSTORE compared $when: $strategyId "$name" not compared: '
              '$why',
              problem: false,
            ),
          ],
        Compared(:final pages, :final unjudged, :final differences) => [
            if (unjudged.isNotEmpty || differences == null)
              CloudStoreLine(
                'CLOUDSTORE compared $when: $strategyId has a result of the '
                'server\'s with no verdict: '
                '${[
                  ...unjudged,
                  if (differences == null) 'the strategy'
                ].join('; ')}',
                problem: true,
              ),
            if (differences != null && differences.isEmpty)
              CloudStoreLine(
                'CLOUDSTORE compared $when: $strategyId equal to the server\'s '
                'copy read as $readAs, $pages pages',
                problem: false,
              ),
            for (final difference in differences ?? const <String>[])
              switch (excusedBy(difference, lagging)) {
                (:final why, row: _) => CloudStoreLine(
                    'CLOUDSTORE compared $when: $strategyId behind the server '
                    'on a row the script named ($why): $difference',
                    problem: false,
                  ),
                null => CloudStoreLine(
                    'CLOUDSTORE compared $when: $strategyId: $difference',
                    problem: true,
                  ),
              },
          ],
      },
  ];
}

CloudStoreLine? _senderReportLine(SenderReport report) => switch (report) {
      EventsWritten(:final strategyId, :final events, :final batch) =>
        CloudStoreLine(
          'CLOUDSTORE recorded for $strategyId'
          '${batch == null ? '' : ' (${batch.ops.length} ops sent as client ${batch.clientId})'}: '
          '${events.map(_eventWords).join('; ')}',
          problem: false,
        ),
      EventNotApplied(:final strategyId, :final why) => CloudStoreLine(
          'CLOUDSTORE the queue of $strategyId did not apply an event: $why',
          problem: false,
        ),
      SessionOpenedFor(:final strategyId, :final session, :final stamp) =>
        CloudStoreLine(
          'CLOUDSTORE the sender opened session $session of $strategyId for '
          'connection ${stamp.connection} and ${stamp.account?.subject}',
          problem: false,
        ),
      ReadRecorded(:final strategyId, :final read, :final why) =>
        CloudStoreLine(
          'CLOUDSTORE read $read of $strategyId as its account ($why)',
          problem: false,
        ),
      BatchSentAs(:final strategyId, :final batch) => CloudStoreLine(
          'CLOUDSTORE sending attempt ${batch.attempt} of $strategyId in '
          'session ${batch.session}: '
          '${switch (batch.unchecked) {
            [] => 'every op checked',
            final live =>
              'unchecked ${live.join(', ')} on basis ${batch.basis}',
          }}'
          '${batch.ops.length > batch.unchecked.length && batch.unchecked.isNotEmpty ? ', the rest checked' : ''}',
          problem: false,
        ),
      UncheckedWithoutBasis(:final strategyId, :final batch) => CloudStoreLine(
          'CLOUDSTORE attempt ${batch.attempt} of $strategyId went out with '
          'unchecked ops ${batch.unchecked.join(', ')} and no basis, and the '
          'server refused it for that: the queue must never send this',
          problem: true,
        ),
      StoredRowsRefused(:final strategyId, :final refusal) => CloudStoreLine(
          'CLOUDSTORE the rows stored for $strategyId disagree with its '
          'queue, so the store refuses it: ${refusal.reason}',
          problem: true,
        ),
      StoredResultsDroppedReport(:final strategyId, :final dropped) =>
        CloudStoreLine(
          'CLOUDSTORE the stored results of $strategyId could not be read '
          '(${dropped.group}: ${dropped.problem}), so the store dropped them '
          'and starts its results again from the rows it holds',
          problem: false,
        ),
      HeldRowsNotRead(:final strategyId, :final why) => CloudStoreLine(
          'CLOUDSTORE the rows the store holds for a watched page of '
          '$strategyId could not be read ($why), so its next answer is '
          'decoded whole',
          problem: true,
        ),
      WriteNotMade(:final strategyId, :final trouble) => CloudStoreLine(
          'CLOUDSTORE a write for $strategyId was not made '
          '(${trouble.runtimeType}): ${trouble.why}',
          problem: true,
        ),
    };

String _clockTime(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}:'
    '${time.second.toString().padLeft(2, '0')}.'
    '${time.millisecond.toString().padLeft(3, '0')}';

String _eventWords(QueueEvent event) => switch (event) {
      OpAnswered(
        :final attempt,
        answer: AppliedAnswer(:final opId, :final revision)
      ) =>
        'attempt $attempt: $opId applied at revision $revision',
      OpAnswered(
        :final attempt,
        answer: NoopAnswer(:final opId, :final revision, :final replay)
      ) =>
        'attempt $attempt: $opId changed nothing at revision $revision (${replay.name})',
      OpAnswered(:final attempt, answer: NoopWithoutRevision(:final opId)) =>
        'attempt $attempt: $opId changed nothing',
      OpAnswered(
        :final attempt,
        answer: RejectedAnswer(:final opId, :final reason)
      ) =>
        'attempt $attempt: $opId rejected (${reason.wireName})',
      OpAnswered(
        :final attempt,
        answer: FailedAnswer(:final opId, :final code)
      ) =>
        'attempt $attempt: $opId failed ($code)',
      TransportFailed(:final attempt, :final failure) =>
        'attempt $attempt: no answer (${failure.name})',
      BatchRefused(:final attempt, :final refusal) =>
        'attempt $attempt refused whole (${refusal.name})',
      BatchAccountMismatch(:final attempt) =>
        'attempt $attempt refused for another account',
      ClaimReleased(:final attempt) => 'attempt $attempt given back unsent',
      UserUsedCloud(:final opId) =>
        'the user took the cloud\'s version of $opId',
      ServerTimeHeld(:final serverTime, :final session) =>
        'server time $serverTime held for session $session',
      _ => '${event.runtimeType}',
    };

String _opened(LibraryStoreOpened opened) => switch (opened) {
      LibraryStoreReady() => 'opened',
      LibraryStoreHeldElsewhere() => 'held by another instance of the app',
      LibraryStoreRefused(:final failure) =>
        '${storageFailureWords(failure, StoreStep.opening)} ($failure)',
      LibraryStoreTooSmall(:final maxKeyLength) =>
        'the engine holds keys of only $maxKeyLength characters',
    };
