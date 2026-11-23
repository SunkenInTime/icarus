import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart'
    show AppliedOpAck, ElementDeleteOp;
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus_library/icarus_library.dart' hide ElementDeleteOp;

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
  final cloud = _storedCloudStrategies(_running(c).store);
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
  final shadow = _running(c);
  await shadow.idle;
  final store = shadow.store;
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

  bool isOn(ProviderContainer c) => c.exists(cloudShadowProvider);

  List<CloudStoreLine> drain(ProviderContainer c) {
    if (!isOn(c)) return const [];
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

  Future<List<CloudStoreLine>> end(
    ProviderContainer c, {
    required DateTime lastStep,
  }) async {
    if (!isOn(c)) return const [];
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
      case CloudShadowRunning(:final shadow):
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

  List<CloudStoreLine> closeFailed(ProviderContainer c, Object error) {
    if (!isOn(c)) return const [];
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
        final compared = await state.shadow.readBack(store);
        await store.close();
        await closeEngine();
        return [
          if (compared.isEmpty)
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

String _opened(LibraryStoreOpened opened) => switch (opened) {
      LibraryStoreReady() => 'opened',
      LibraryStoreHeldElsewhere() => 'held by another instance of the app',
      LibraryStoreRefused(:final failure) =>
        '${storageFailureWords(failure, StoreStep.opening)} ($failure)',
      LibraryStoreTooSmall(:final maxKeyLength) =>
        'the engine holds keys of only $maxKeyLength characters',
    };
