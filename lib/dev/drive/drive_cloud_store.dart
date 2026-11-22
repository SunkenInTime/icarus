import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/storage_failure_words.dart';

String cloudSwitchName(CloudStoreSwitch choice) => switch (choice) {
      CloudStoreOff() => 'off',
      CloudStoreShadow() => 'shadow',
    };

final class CloudStoreLine {
  const CloudStoreLine(this.text, {required this.problem});

  final String text;
  final bool problem;
}

final class CloudStoreLog {
  int _read = 0;
  int equal = 0;

  List<CloudStoreLine> drain(ProviderContainer c) {
    final state = c.read(cloudShadowProvider);
    if (state is! CloudShadowRunning) return const [];
    final reports = state.shadow.reports;
    final fresh = reports.sublist(_read);
    _read = reports.length;
    final checked = fresh.whereType<ShadowEqual>().toList();
    final recorded = fresh.whereType<ShadowRecorded>().toList();
    equal += checked.length;
    return [
      for (final report in fresh)
        if (report is! ShadowEqual && report is! ShadowRecorded)
          ..._lines(report),
      if (recorded.isNotEmpty || checked.isNotEmpty)
        CloudStoreLine(
          'CLOUDSTORE recorded ${recorded.length} results '
          '(${_sessions(recorded)}), ${checked.length} checks equal '
          '(${_pages(checked)})',
          problem: false,
        ),
    ];
  }

  String _sessions(List<ShadowRecorded> recorded) {
    final lists = recorded.where((report) => report.what == 'the page list');
    final sessions = {for (final report in recorded) report.session};
    return '${lists.length} page lists, '
        '${recorded.length - lists.length} page results, '
        'session ${sessions.join(', ')}';
  }

  String _pages(List<ShadowEqual> checked) {
    final rows = <String, int>{};
    for (final report in checked) {
      rows[report.pageId] = report.rows;
    }
    return [
      for (final MapEntry(:key, :value) in rows.entries) '$key: $value rows',
    ].join('; ');
  }

  Future<List<CloudStoreLine>> end(ProviderContainer c) async {
    if (c.read(cloudStoreSwitchProvider) is CloudStoreOff) return const [];
    final state = c.read(cloudShadowProvider);
    switch (state) {
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
        await shadow.idle
            .timeout(const Duration(seconds: 10), onTimeout: () {});
        final lines = drain(c);
        return [
          ...lines,
          CloudStoreLine(
            'CLOUDSTORE end: $equal checks equal',
            problem: false,
          ),
          if (equal == 0)
            const CloudStoreLine(
              'CLOUDSTORE no check ran: the open page was never compared',
              problem: true,
            ),
        ];
    }
  }
}

String _opened(LibraryStoreOpened opened) => switch (opened) {
      LibraryStoreReady() => 'opened',
      LibraryStoreHeldElsewhere() => 'held by another instance of the app',
      LibraryStoreRefused(:final failure) =>
        '${storageFailureWords(failure, StoreStep.opening)} ($failure)',
      LibraryStoreTooSmall(:final maxKeyLength) =>
        'the engine holds keys of only $maxKeyLength characters',
    };

List<CloudStoreLine> _lines(CloudShadowReport report) => switch (report) {
      ShadowSessionOpened(:final strategyId, :final session, :final because) =>
        [
          CloudStoreLine(
            'CLOUDSTORE session $session for $strategyId: $because',
            problem: false,
          ),
        ],
      ShadowConnectionLost(:final strategyId) => [
          CloudStoreLine(
            'CLOUDSTORE connection dropped for $strategyId',
            problem: false,
          ),
        ],
      ShadowRecorded(:final strategyId, :final what, :final session) => [
          CloudStoreLine(
            'CLOUDSTORE recorded $what of $strategyId in session $session',
            problem: false,
          ),
        ],
      ShadowNotApplied(:final strategyId, :final what, :final why) => [
          CloudStoreLine(
            'CLOUDSTORE not applied $what of $strategyId: $why',
            problem: false,
          ),
        ],
      ShadowSkipped(:final strategyId, :final what, :final why) => [
          CloudStoreLine(
            'CLOUDSTORE skipped $what of $strategyId: $why',
            problem: false,
          ),
        ],
      ShadowEqual(:final strategyId, :final pageId, :final rows) => [
          CloudStoreLine(
            'CLOUDSTORE equal $strategyId page $pageId: $rows rows',
            problem: false,
          ),
        ],
      ShadowDiffers(:final strategyId, :final pageId, :final differences) => [
          for (final difference in differences)
            CloudStoreLine(
              'CLOUDSTORE difference $strategyId page $pageId: $difference',
              problem: true,
            ),
        ],
      ShadowStoreFailed(:final what, :final failure) => [
          CloudStoreLine(
            'CLOUDSTORE store failed $what: ${report.words} ($failure)',
            problem: true,
          ),
        ],
      ShadowRefused(:final strategyId, :final what, :final refusal) => [
          CloudStoreLine(
            'CLOUDSTORE refused $what of $strategyId: '
            '${refusal.runtimeType} $refusal',
            problem: true,
          ),
        ],
    };
