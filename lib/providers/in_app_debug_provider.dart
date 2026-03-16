import 'package:flutter_riverpod/flutter_riverpod.dart';

final inAppDebugProvider =
    NotifierProvider<InAppDebugProvider, List<DebugLogEntry>>(
        InAppDebugProvider.new);

enum DebugLogLevel { info, warning, error }

class DebugLogEntry {
  const DebugLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.source,
    this.errorText,
    this.stackTrace,
  });

  final DateTime timestamp;
  final DebugLogLevel level;
  final String message;
  final String? source;
  final String? errorText;
  final String? stackTrace;

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

  String toClipboardText() {
    final buffer = StringBuffer()
      ..writeln(headline)
      ..writeln(message);

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

class InAppDebugProvider extends Notifier<List<DebugLogEntry>> {
  static const int _maxEntries = 500;

  @override
  List<DebugLogEntry> build() {
    return [];
  }

  void addEntry(DebugLogEntry entry) {
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
