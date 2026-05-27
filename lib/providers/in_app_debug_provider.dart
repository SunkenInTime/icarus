import 'package:flutter_riverpod/flutter_riverpod.dart';

final inAppDebugProvider =
    NotifierProvider<InAppDebugProvider, List<DebugLogEntry>>(
        InAppDebugProvider.new);

enum DebugLogLevel { info, warning, error }

class DebugLogEntry {
  DebugLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.source,
    this.errorText,
    this.stackTrace,
    String? dedupeKey,
    this.repeatCount = 1,
    DateTime? lastOccurredAt,
  })  : dedupeKey = dedupeKey ??
            _buildDebugLogDedupeKey(
              level: level,
              message: message,
              source: source,
              errorText: errorText,
              stackTrace: stackTrace,
            ),
        lastOccurredAt = lastOccurredAt ?? timestamp;

  final DateTime timestamp;
  final DebugLogLevel level;
  final String message;
  final String? source;
  final String? errorText;
  final String? stackTrace;
  final String dedupeKey;
  final int repeatCount;
  final DateTime lastOccurredAt;

  String get levelLabel => switch (level) {
        DebugLogLevel.info => 'INFO',
        DebugLogLevel.warning => 'WARN',
        DebugLogLevel.error => 'ERROR',
      };

  String get headline {
    final sourceLabel =
        source == null || source!.trim().isEmpty ? '' : ' [$source]';
    return '[${formatDebugLogTimestamp(timestamp)}] $levelLabel$sourceLabel';
  }

  bool canMergeWith(DebugLogEntry other) => dedupeKey == other.dedupeKey;

  String get repeatLabel => 'Repeated ${repeatCount}x';

  DebugLogEntry mergeRepeat(DebugLogEntry other) {
    final currentErrorText = errorText?.trim();
    final currentStackTrace = stackTrace?.trim();

    return DebugLogEntry(
      timestamp: timestamp,
      level: level,
      message: message,
      source: source,
      errorText: currentErrorText != null && currentErrorText.isNotEmpty
          ? errorText
          : other.errorText,
      stackTrace: currentStackTrace != null && currentStackTrace.isNotEmpty
          ? stackTrace
          : other.stackTrace,
      dedupeKey: dedupeKey,
      repeatCount: repeatCount + other.repeatCount,
      lastOccurredAt: other.lastOccurredAt,
    );
  }

  String toClipboardText() {
    final buffer = StringBuffer()..writeln(headline);

    if (repeatCount > 1) {
      buffer.writeln(
        '$repeatLabel (latest: ${formatDebugLogTimestamp(lastOccurredAt)})',
      );
    }

    buffer.writeln(message);

    if (errorText != null && errorText!.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Error: $errorText');
    }

    if (stackTrace != null && stackTrace!.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Stack trace:')
        ..writeln(stackTrace);
    }

    return buffer.toString().trimRight();
  }
}

String formatDebugLogTimestamp(DateTime timestamp) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');

  return '${timestamp.year}-'
      '${twoDigits(timestamp.month)}-'
      '${twoDigits(timestamp.day)} '
      '${twoDigits(timestamp.hour)}:'
      '${twoDigits(timestamp.minute)}:'
      '${twoDigits(timestamp.second)}';
}

String _buildDebugLogDedupeKey({
  required DebugLogLevel level,
  required String message,
  String? source,
  String? errorText,
  String? stackTrace,
}) {
  return [
    level.name,
    _normalizeDebugLogFragment(source),
    _normalizeDebugLogFragment(message),
    _normalizeDebugLogFragment(errorText),
    _normalizeDebugLogFragment(_firstStackTraceLine(stackTrace)),
  ].join('|');
}

String _normalizeDebugLogFragment(String? value) {
  if (value == null) return '';

  return value.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String? _firstStackTraceLine(String? stackTrace) {
  if (stackTrace == null) return null;

  for (final line in stackTrace.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }

  return null;
}

class InAppDebugProvider extends Notifier<List<DebugLogEntry>> {
  static const int _maxEntries = 500;

  @override
  List<DebugLogEntry> build() {
    return [];
  }

  void addEntry(DebugLogEntry entry) {
    if (state.isNotEmpty && state.last.canMergeWith(entry)) {
      final mergedEntry = state.last.mergeRepeat(entry);
      state = [...state.sublist(0, state.length - 1), mergedEntry];
      return;
    }

    final nextState = [...state, entry];
    if (nextState.length <= _maxEntries) {
      state = nextState;
      return;
    }

    state = nextState.sublist(nextState.length - _maxEntries);
  }

  void addLog({
    required String message,
    DebugLogLevel level = DebugLogLevel.info,
    String? source,
    String? errorText,
    String? stackTrace,
  }) {
    addEntry(
      DebugLogEntry(
        timestamp: DateTime.now(),
        level: level,
        message: message,
        source: source,
        errorText: errorText,
        stackTrace: stackTrace,
      ),
    );
  }

  void bulkAddLogs(List<String> logs, {String? source}) {
    for (final log in logs) {
      addLog(message: log, source: source);
    }
  }

  void clearLogs() {
    state = [];
  }
}
