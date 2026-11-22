import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
import 'package:icarus/library_store/shadow_store.dart';
import 'package:icarus/library_store/storage_failure_words.dart';
import 'package:icarus_library/icarus_library.dart';

String storedCloudStrategy(ProviderContainer c) {
  if (!c.exists(cloudShadowProvider)) {
    throw StateError('the cloud store shadow is off');
  }
  final state = c.read(cloudShadowProvider);
  if (state is! CloudShadowRunning) {
    throw StateError('the cloud store shadow is not running');
  }
  final library = state.shadow.store.library;
  if (library is! LibraryOpen) throw StateError('the store is shut');
  final cloud = [
    for (final summary in library.list.strategies)
      if (summary.sync is KeptInCloud || summary.sync is CloudUnverified)
        summary.publicId,
  ];
  if (cloud.length != 1) {
    throw StateError('the store holds ${cloud.length} cloud strategies');
  }
  return cloud.single;
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

  Future<List<CloudStoreLine>> end(ProviderContainer c) async {
    if (!isOn(c)) return const [];
    switch (c.read(cloudShadowProvider)) {
      case CloudShadowIdle():
        return const [
          CloudStoreLine('CLOUDSTORE never started', problem: true),
        ];
      case CloudShadowNotOpened(:final opened):
        return [
          CloudStoreLine(
            'CLOUDSTORE store not opened: ${_opened(opened)}',
            problem: true,
          ),
        ];
      case CloudShadowRunning(:final shadow):
        final finished = await shadow.idle
            .then((_) => true)
            .timeout(_finalWait, onTimeout: () => false);
        final ledger = shadow.ledger;
        final equal = ledger.where((entry) => entry.verdict is ComparedEqual);
        final skipped = ledger.where((entry) => entry.verdict is Skipped);
        final different =
            ledger.where((entry) => entry.verdict is ComparedDifferent);
        final notRecorded =
            ledger.where((entry) => entry.verdict is NotRecorded);
        final waiting = ledger.where((entry) => entry.verdict is NotProcessed);
        return [
          ...drain(c),
          if (!finished)
            CloudStoreLine(
              'CLOUDSTORE the shadow had work left after '
              '${_finalWait.inSeconds} s',
              problem: true,
            ),
          for (final entry in waiting)
            CloudStoreLine(
              'CLOUDSTORE not processed: ${entry.what} of ${entry.strategyId}',
              problem: true,
            ),
          CloudStoreLine(
            'CLOUDSTORE verdict: ${ledger.length} results delivered, '
            '${equal.length} compared equal, ${different.length} compared '
            'different, ${notRecorded.length} not recorded, ${waiting.length} '
            'not processed${_skips(skipped)}',
            problem: false,
          ),
          if (equal.isEmpty)
            const CloudStoreLine(
              'CLOUDSTORE no result was compared',
              problem: true,
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
        final differences = await state.shadow.differencesIn(store);
        await store.close();
        await closeEngine();
        return [
          if (differences.isEmpty)
            const CloudStoreLine(
              'CLOUDSTORE read back after reopening the store: equal',
              problem: false,
            ),
          for (final difference in differences)
            CloudStoreLine(
              'CLOUDSTORE read back after reopening the store: $difference',
              problem: true,
            ),
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
      NotRecorded(:final why) => [
          CloudStoreLine(
            'CLOUDSTORE not recorded: ${entry.what} of ${entry.strategyId}: '
            '$why',
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
      ShadowReadFailed(:final strategyId, :final error) => CloudStoreLine(
          'CLOUDSTORE the page list watch of $strategyId failed: $error',
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
