import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

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

final class CloudStoreLine {
  const CloudStoreLine(this.text, {required this.problem});

  final String text;
  final bool problem;
}

const _finalWait = Duration(seconds: 30);

final class CloudStoreLog {
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
          'CLOUDSTORE ${settled.length} results settled: ${equal.length} '
          'compared equal${_skips(skipped)}',
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
        await c.read(cloudShadowProvider.notifier).stopSubscriptions();
        final left = _finalWait - DateTime.now().difference(lastStep);
        final finished = await shadow.idle.then((_) => true).timeout(
              left.isNegative ? Duration.zero : left,
              onTimeout: () => false,
            );
        final ledger = shadow.ledger;
        int count<T extends Verdict>() =>
            ledger.where((entry) => entry.verdict is T).length;
        final open = ledger.where((entry) => entry.verdict is NotProcessed);
        final strategies = {for (final entry in ledger) entry.strategyId};
        final unchecked = [
          for (final strategyId in strategies)
            if (!ledger.any(
              (entry) =>
                  entry.strategyId == strategyId &&
                  entry.verdict is ComparedEqual,
            ))
              strategyId,
        ];
        return [
          ...drain(c),
          if (!finished)
            CloudStoreLine(
              'CLOUDSTORE the shadow had work left '
              '${_finalWait.inSeconds} s after the last step',
              problem: true,
            ),
          for (final entry in open)
            CloudStoreLine(
              'CLOUDSTORE not processed: ${entry.what} of ${entry.strategyId}',
              problem: true,
            ),
          for (final strategyId in unchecked)
            CloudStoreLine(
              'CLOUDSTORE no result of $strategyId was compared equal',
              problem: true,
            ),
          if (ledger.isEmpty)
            const CloudStoreLine(
              'CLOUDSTORE no result was delivered',
              problem: true,
            ),
          CloudStoreLine(
            'CLOUDSTORE verdict: ${ledger.length} results delivered for '
            '${strategies.length} strategies, ${count<ComparedEqual>()} '
            'compared equal, ${count<ComparedDifferent>()} compared '
            'different, ${count<RefusedByStore>()} refused by the store, '
            '${count<ReadFailed>()} failed, ${open.length} not processed'
            '${_skips(ledger.where((entry) => entry.verdict is Skipped))}',
            problem: false,
          ),
        ];
    }
  }

  Future<List<CloudStoreLine>> readBack(ProviderContainer c) async {
    if (!isOn(c)) return const [];
    final state = c.read(cloudShadowProvider);
    if (state is! CloudShadowRunning) return const [];
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
                'equal, whole',
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
            'CLOUDSTORE failed: ${entry.what} of ${entry.strategyId}: $why',
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
