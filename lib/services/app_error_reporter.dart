import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/widgets/dialogs/in_app_debug_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AppErrorReporter {
  static bool _isDebugDialogOpen = false;
  static File? _persistedLogFile;
  static Future<void> _persistedLogWriteQueue = Future.value();

  static Future<void> initializePersistedLog(String logFilePath) async {
    final logFile = File(logFilePath);

    try {
      await logFile.parent.create(recursive: true);
      if (!await logFile.exists()) {
        await logFile.create(recursive: true);
      }
      _persistedLogFile = logFile;
    } catch (error, stackTrace) {
      _persistedLogFile = null;
      developer.log(
        'Failed to initialize persisted debug log.',
        name: 'AppErrorReporter.initializePersistedLog',
        error: error,
        stackTrace: stackTrace,
        level: 900,
      );
    }
  }

  static void reportInfo(
    String message, {
    String? source,
    Object? error,
    StackTrace? stackTrace,
  }) {
    addDebugLog(
      message,
      level: DebugLogLevel.info,
      source: source,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static void reportWarning(
    String message, {
    String? source,
    Object? error,
    StackTrace? stackTrace,
    bool promptUser = false,
  }) {
    addDebugLog(
      message,
      level: DebugLogLevel.warning,
      source: source,
      error: error,
      stackTrace: stackTrace,
    );

    if (promptUser && _canShowInteractiveUi) {
      Settings.showToast(
        message: message,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
        actionLabel: 'Open Logs',
        onActionPressed: () {
          unawaited(openDebugLog());
        },
      );
    }
  }

  static void reportError(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? source,
    bool promptUser = true,
  }) {
    addDebugLog(
      message,
      level: DebugLogLevel.error,
      source: source,
      error: error,
      stackTrace: stackTrace,
    );

    if (promptUser && _canShowInteractiveUi) {
      Settings.showToast(
        message: message,
        backgroundColor: Settings.tacticalVioletTheme.destructive,
        actionLabel: 'Open Logs',
        onActionPressed: () {
          unawaited(openDebugLog());
        },
      );
    }
  }

  static void addDebugLog(
    String message, {
    DebugLogLevel level = DebugLogLevel.info,
    String? source,
    Object? error,
    StackTrace? stackTrace,
  }) {
    final entry = DebugLogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      source: source,
      errorText: error?.toString(),
      stackTrace: stackTrace?.toString(),
    );

    developer.log(
      message,
      name: source ?? 'Icarus',
      error: error,
      stackTrace: stackTrace,
      level: _developerLogLevel(level),
    );

    appProviderContainer.read(inAppDebugProvider.notifier).addEntry(entry);
    _queuePersistedLogWrite(entry);
  }

  static Future<void> openDebugLog() async {
    if (_isDebugDialogOpen) return;

    final navCtx = appNavigatorKey.currentContext ??
        appNavigatorKey.currentState?.overlay?.context;
    if (navCtx == null) return;

    _isDebugDialogOpen = true;
    try {
      await showShadDialog<void>(
        context: navCtx,
        builder: (context) => const InAppDebugDialog(),
      );
    } finally {
      _isDebugDialogOpen = false;
    }
  }

  static String buildClipboardReport(Iterable<DebugLogEntry> entries) {
    final entryList = entries.toList(growable: false);
    final buffer = StringBuffer()
      ..writeln('Icarus Debug Report')
      ..writeln('Generated: ${formatDebugLogTimestamp(DateTime.now())}')
      ..writeln();

    if (entryList.isEmpty) {
      buffer.writeln('No logs recorded.');
      return buffer.toString().trimRight();
    }

    for (var i = 0; i < entryList.length; i++) {
      buffer.writeln(entryList[i].toClipboardText());
      if (i != entryList.length - 1) {
        buffer
          ..writeln()
          ..writeln('-----')
          ..writeln();
      }
    }

    return buffer.toString().trimRight();
  }

  static bool get _canShowInteractiveUi =>
      appNavigatorKey.currentContext != null ||
      appNavigatorKey.currentState?.overlay?.context != null;

  static int _developerLogLevel(DebugLogLevel level) {
    return switch (level) {
      DebugLogLevel.info => 800,
      DebugLogLevel.warning => 900,
      DebugLogLevel.error => 1000,
    };
  }

  static void _queuePersistedLogWrite(DebugLogEntry entry) {
    final logFile = _persistedLogFile;
    if (logFile == null) return;

    _persistedLogWriteQueue = _persistedLogWriteQueue
        .catchError((Object _, StackTrace __) {})
        .then((_) => _appendPersistedLogEntry(logFile, entry))
        .catchError((Object error, StackTrace stackTrace) {
      developer.log(
        'Failed to append to persisted debug log.',
        name: 'AppErrorReporter._queuePersistedLogWrite',
        error: error,
        stackTrace: stackTrace,
        level: 900,
      );
    });
  }

  static Future<void> _appendPersistedLogEntry(
    File logFile,
    DebugLogEntry entry,
  ) async {
    final buffer = StringBuffer()
      ..writeln(entry.toClipboardText())
      ..writeln()
      ..writeln('-----')
      ..writeln();

    await logFile.writeAsString(
      buffer.toString(),
      mode: FileMode.append,
      flush: true,
    );
  }
}
