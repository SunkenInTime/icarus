import 'dart:async';
import 'dart:math';

import 'package:flutter/painting.dart' show Offset;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart'
    show AppliedOpAck, ElementDeleteOp;
import 'package:icarus/collab/convex_client.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus_library/icarus_library.dart' hide ElementDeleteOp;
import 'package:uuid/uuid.dart';

CloudShadow _running(ProviderContainer c) {
  if (!c.exists(cloudShadowProvider)) {
    throw StateError('the cloud store shadow is off');
  }
  final state = c.read(cloudShadowProvider);
  if (state is! CloudShadowRunning) {
    throw StateError('the cloud store shadow is not running');
  }
  return state.shadow;
}

CloudSender? _sending(ProviderContainer c) =>
    c.exists(cloudSenderProvider) ? c.read(cloudSenderProvider) : null;

CloudSender _sender(ProviderContainer c) =>
    _sending(c) ??
    (throw StateError('the cloud store does not send in this run'));

LibraryStore _storeOf(ProviderContainer c) =>
    _sending(c)?.store.store ?? _running(c).store;

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
  final saved = await store.commitAllAs(_signedIn(c), strategyId, [op]);
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
  final saved = await store.commitAllAs(_signedIn(c), strategyId, [op]);
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
          final saved = await store.commitAllAs(_signedIn(c), strategyId, [
            op,
          ]);
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
  final saved = await store.commitAllAs(_signedIn(c), strategyId, [op]);
  if (saved is! Saved) throw StateError('the store did not take it: $saved');
  return 'CLOUDSTORE committed ${op.opId}: delete page $page of $strategyId '
      'with no editor open';
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

Future<List<(String, CloudStrategy)>> _cloudQueues(LibraryStore store) async {
  final queues = <(String, CloudStrategy)>[];
  for (final strategyId in _storedCloudStrategies(store)) {
    switch (await store.readStrategy(strategyId)) {
      case Found(value: StrategyContent(sync: final CloudStrategy cloud)):
        queues.add((strategyId, cloud));
      case final other:
        throw StateError('the queue of $strategyId could not be read: $other');
    }
  }
  return queues;
}

Future<String> waitStoreSent(
  ProviderContainer c,
  Duration within, {
  bool landedMayWait = false,
}) async {
  final store = _storeOf(c);
  final until = DateTime.now().add(within);
  while (true) {
    final queues = await _cloudQueues(store);
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
          '; sender ${_senderWords(c)}';
    }
    if (DateTime.now().isAfter(until)) {
      throw StateError(
        'work left after ${within.inSeconds} s: ${left.join('; ')}; sender '
        '${_senderWords(c)}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

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

Future<String> storedPayloadVersion(
  ProviderContainer c,
  String itemId,
  int version,
) async {
  if (_sending(c) == null) await _running(c).idle;
  final store = _storeOf(c);
  for (final strategyId in _storedCloudStrategies(store)) {
    final read = await store.readStrategy(strategyId);
    if (read is! Found<StrategyContent>) continue;
    for (final page in read.value.pages) {
      final content = await store.readPage(strategyId, page.publicId);
      if (content is! Found<PageContent>) continue;
      for (final element in content.value.elements) {
        if (element case LiveElement(:final publicId, :final payload)
            when publicId == itemId) {
          if (payload.payloadVersion != version) {
            throw StateError(
              'the store holds $itemId at payload version '
              '${payload.payloadVersion}, not $version',
            );
          }
          return 'CLOUDSTORE the store holds $itemId at payload version '
              '${payload.payloadVersion}, as the server sent it';
        }
      }
    }
  }
  throw StateError('the store holds no item $itemId');
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

  int _reportsRead = 0;
  final _settled = <LedgerEntry>{};
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

  bool isOn(ProviderContainer c) =>
      c.exists(cloudShadowProvider) || c.exists(cloudSenderProvider);

  bool sends(ProviderContainer c) => c.exists(cloudSenderProvider);

  List<CloudStoreLine> drain(ProviderContainer c) {
    if (!isOn(c)) return const [];
    if (sends(c)) return _senderDrain(c);
    final state = c.read(cloudShadowProvider);
    if (state is! CloudShadowRunning) return const [];
    final shadow = state.shadow;
    final reports = shadow.reports.sublist(_reportsRead);
    _reportsRead = shadow.reports.length;
    final settled = [
      for (final entry in shadow.ledger)
        if (entry.verdict is! NotProcessed && _settled.add(entry)) entry,
    ];
    final equal = settled.where((entry) => entry.verdict is ComparedEqual);
    final skipped = settled.where((entry) => entry.verdict is Skipped);
    return [
      for (final report in reports) _reportLine(report),
      for (final entry in settled) ..._problemLines(entry),
      if (equal.isNotEmpty || skipped.isNotEmpty)
        CloudStoreLine(
          'CLOUDSTORE ${settled.length} results settled '
          '(${settled.where((entry) => entry.pageId != null).length} pages): '
          '${equal.length} compared equal${_skips(skipped)}',
          problem: false,
        ),
    ];
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
    if (sends(c)) return _senderEnd(c, lastStep);
    switch (c.read(cloudShadowProvider)) {
      case CloudShadowIdle():
        return const [
          CloudStoreLine('CLOUDSTORE never started', problem: true),
        ];
      case CloudShadowFailed(:final reason):
        return [
          CloudStoreLine('CLOUDSTORE could not start: $reason', problem: true),
        ];
      case CloudShadowNotOpened(:final opened):
        return [
          CloudStoreLine(
            'CLOUDSTORE store not opened: ${_opened(opened)}',
            problem: true,
          ),
        ];
      case final CloudShadowRunning state:
        final shadow = state.shadow;
        final notifier = c.read(cloudShadowProvider.notifier)..cutoff();
        final drained = await notifier.drained(lastStep.add(finalWait));
        notifier.detach();
        final ledger = shadow.ledger;
        int count<T extends Verdict>() =>
            ledger.where((entry) => entry.verdict is T).length;
        final recordedPages = ledger.where(
          (entry) =>
              entry.pageId != null &&
              (entry.verdict is ComparedEqual ||
                  entry.verdict is ComparedDifferent),
        );
        final waiting =
            ledger.where((entry) => entry.verdict is NotProcessed).length;
        return [
          ...drain(c),
          if (shadow.ended case final reason?)
            CloudStoreLine(
              'CLOUDSTORE ended: $reason; nothing after it is recorded',
              problem: false,
            ),
          if (!drained.idle)
            CloudStoreLine(
              'CLOUDSTORE the shadow had work left '
              '${finalWait.inSeconds} s after the last step',
              problem: true,
            ),
          if (drained.watchesOpen > 0)
            CloudStoreLine(
              'CLOUDSTORE ${drained.watchesOpen} page list watches had not '
              'closed ${finalWait.inSeconds} s after the last step',
              problem: true,
            ),
          if (notifier.subject case final subject?)
            CloudStoreLine(
              'CLOUDSTORE page lists were read naming account $subject',
              problem: false,
            ),
          CloudStoreLine(
            'CLOUDSTORE counted, not judged: ${notifier.handed} pages handed '
            'to the editor, ${recordedPages.length} recorded by the shadow'
            '${_skips(ledger.where((entry) => entry.verdict is Skipped))}'
            '${[
              for (final MapEntry(:key, :value) in notifier.notTaken.entries)
                ', $value not taken: $key',
            ].join()}'
            '${drained.idle && waiting > 0 ? ', $waiting never recorded: '
                'they waited for a page list' : ''}',
            problem: false,
          ),
          CloudStoreLine(
            'CLOUDSTORE verdict: ${count<ComparedEqual>() + count<ComparedDifferent>()} '
            'results recorded for ${shadow.strategies.length} strategies, '
            '${count<ComparedEqual>()} compared equal, '
            '${count<ComparedDifferent>()} compared different, '
            '${count<RefusedByStore>()} refused by the store, '
            '${count<ReadFailed>()} unreadable',
            problem: false,
          ),
        ];
    }
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
          '${switch (c.read(cloudSenderProvider.notifier).opened) {
            final opened? => _opened(opened),
            null => 'the store had not opened',
          }}',
          problem: true,
        ),
      ];
    }
    final deadline = lastStep.add(finalWait);
    final stopping = await _senderStopped(c, deadline);
    final left = await _workLeft(sender.store.store);
    final asLeft = await _compareWithServer(
      c,
      sender.store.store,
      build: sender.build,
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
    if (sends(c)) {
      return [
        CloudStoreLine(
          'CLOUDSTORE closing the store failed: $error',
          problem: true,
        ),
      ];
    }
    if (c.read(cloudShadowProvider) case CloudShadowRunning(:final shadow)) {
      shadow.stop('closing the store failed: $error');
    }
    return [
      CloudStoreLine(
        'CLOUDSTORE closing the store failed: $error',
        problem: true,
      ),
    ];
  }

  Future<List<CloudStoreLine>> readBack(ProviderContainer c) async {
    if (!isOn(c)) return const [];
    if (sends(c)) return _namedReadBack(c, expected, lagging);
    final state = c.read(cloudShadowProvider);
    if (state is! CloudShadowRunning) return const [];
    final lateStop = [
      for (final report in state.shadow.reports.sublist(_reportsRead))
        if (report is ShadowStopped)
          CloudStoreLine(
            'CLOUDSTORE stopped after the verdict: ${report.reason}',
            problem: true,
          ),
    ];
    _reportsRead = state.shadow.reports.length;
    return [...lateStop, ...await _readBack(c, state)];
  }

  Future<List<CloudStoreLine>> _readBack(
    ProviderContainer c,
    CloudShadowRunning state,
  ) async {
    if (c.read(libraryStoreProvider) is! LibraryStoreClosed) {
      return const [
        CloudStoreLine(
          'CLOUDSTORE read back skipped: the store was not closed',
          problem: true,
        ),
      ];
    }
    switch (await openLibraryStore(state.file, build: state.shadow.build)) {
      case LibraryStoreReady(:final store, :final closeEngine):
        final ownWorkAfterEnd = {
          for (final (strategyId, cloud) in await _cloudQueues(store))
            if (cloud.queue.landed.isNotEmpty) strategyId,
        };
        final compared = {
          for (final MapEntry(:key, :value)
              in (await state.shadow.readBack(store)).entries)
            if (!ownWorkAfterEnd.contains(key)) key: value,
        };
        await store.close();
        await closeEngine();
        return [
          for (final strategyId in ownWorkAfterEnd)
            CloudStoreLine(
              'CLOUDSTORE read back of $strategyId not compared: this '
              'device\'s own work landed, and no result recorded since '
              'shows it',
              problem: false,
            ),
          if (compared.isEmpty && ownWorkAfterEnd.isEmpty)
            const CloudStoreLine(
              'CLOUDSTORE read back had no strategy to compare',
              problem: true,
            ),
          for (final MapEntry(key: strategyId, value: differences)
              in compared.entries) ...[
            if (differences.isEmpty)
              CloudStoreLine(
                'CLOUDSTORE read back after reopening the store: $strategyId '
                'equal, whole, the work of account '
                '${state.shadow.account?.subject}',
                problem: false,
              ),
            for (final difference in differences)
              CloudStoreLine(
                'CLOUDSTORE read back after reopening the store: $strategyId: '
                '$difference',
                problem: true,
              ),
          ],
        ];
      case final other:
        return [
          CloudStoreLine(
            'CLOUDSTORE read back could not reopen the store: '
            '${_opened(other)}',
            problem: true,
          ),
        ];
    }
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
      final lines = await _compareWithServer(
        c,
        store,
        build: sender.build,
        when: 'after reopening the store',
        expected: expected,
        lagging: lagging,
      );
      await store.close();
      await closeEngine();
      return lines;
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
  required String build,
  required String when,
  required List<ExpectedStrategy> expected,
  required List<LaggingRow> lagging,
}) async {
  final signedIn = _signedIn(c);
  final repository = c.read(convexStrategyRepositoryProvider);
  final held = <ServerComparison>[];
  final library = store.library;
  final summaries = library is LibraryOpen
      ? library.list.strategies
      : const <StrategySummary>[];
  for (final summary in summaries) {
    final owner = switch (summary.sync) {
      KeptInCloud(owner: OwnedBy(:final account)) ||
      CloudUnverified(owner: OwnedBy(:final account)) =>
        account,
      _ => null,
    };
    if (owner == null) continue;
    final strategyId = summary.publicId;
    if (owner != signedIn) {
      held.add(
        (
          strategyId: strategyId,
          name: summary.name,
          verdict: NotCompared(
            'the work of ${owner.subject} while signed in as '
            '${signedIn.subject}',
          ),
        ),
      );
      continue;
    }
    final copy = switch (await LibraryStore.open(
      MemoryEngine(MemoryStorage()),
      canRead: appCanRead,
      build: build,
    )) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };
    final server = CloudShadow(
      copy,
      build: build,
      canRead: appCanRead,
      breathe: () async {},
    )..serve(signedIn);
    try {
      final list = await repository.readPageListAs(
        strategyId,
        accountSubject: signedIn.subject,
      );
      server.pageList(strategyId, list, 0);
      for (final page in list.pages) {
        server.page(
          strategyId,
          await repository.readPageAs(
            strategyPublicId: strategyId,
            pagePublicId: page.page.publicId,
            accountSubject: signedIn.subject,
          ),
          0,
        );
      }
      await server.idle;
      held.add(
        (
          strategyId: strategyId,
          name: summary.name,
          verdict: Compared(
            pages: list.pages.length,
            unjudged: [
              for (final entry in server.ledger)
                if (entry.verdict is! ComparedEqual &&
                    entry.verdict is! ComparedDifferent)
                  '${entry.what}: ${entry.verdict}',
            ],
            differences: (await server.readBack(store))[strategyId],
          ),
        ),
      );
    } catch (error) {
      held.add(
        (
          strategyId: strategyId,
          name: summary.name,
          verdict: NotCompared('could not read the server\'s copy: $error'),
        ),
      );
    } finally {
      await copy.close();
    }
  }
  return comparisonLines(
    when: when,
    readAs: signedIn.subject,
    held: held,
    expected: expected,
    lagging: lagging,
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

String _skips(Iterable<LedgerEntry> skipped) {
  final counts = <SkipReason, int>{};
  for (final entry in skipped) {
    final reason = (entry.verdict as Skipped).reason;
    counts[reason] = (counts[reason] ?? 0) + 1;
  }
  return [
    for (final MapEntry(:key, :value) in counts.entries)
      ', $value skipped: ${key.words}',
  ].join();
}

List<CloudStoreLine> _problemLines(LedgerEntry entry) =>
    switch (entry.verdict) {
      ComparedDifferent(:final differences) => [
          for (final difference in differences)
            CloudStoreLine(
              'CLOUDSTORE difference after ${entry.what} of '
              '${entry.strategyId}: $difference',
              problem: true,
            ),
        ],
      RefusedByStore(:final why) => [
          CloudStoreLine(
            'CLOUDSTORE refused by the store: ${entry.what} of '
            '${entry.strategyId}: $why',
            problem: true,
          ),
        ],
      ReadFailed(:final why) => [
          CloudStoreLine(
            'CLOUDSTORE unreadable: ${entry.what} of ${entry.strategyId}: $why',
            problem: true,
          ),
        ],
      NotProcessed() || ComparedEqual() || Skipped() => const [],
    };

CloudStoreLine _reportLine(CloudShadowReport report) => switch (report) {
      ShadowSessionOpened(:final strategyId, :final session, :final because) =>
        CloudStoreLine(
          'CLOUDSTORE session $session for $strategyId: $because',
          problem: false,
        ),
      ShadowEnded(:final reason) => CloudStoreLine(
          'CLOUDSTORE ended: $reason',
          problem: false,
        ),
      ShadowConnectionLost(:final strategyId) => CloudStoreLine(
          'CLOUDSTORE connection dropped for $strategyId',
          problem: false,
        ),
      ShadowStopped(:final reason) => CloudStoreLine(
          'CLOUDSTORE stopped: $reason',
          problem: true,
        ),
    };

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
      ClaimReleased(:final attempt) => 'attempt $attempt given back unsent',
      UserUsedCloud(:final opId) =>
        'the user took the cloud\'s version of $opId',
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
