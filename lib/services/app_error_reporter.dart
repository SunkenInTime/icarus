import 'dart:async';
import 'dart:developer' as developer;

import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/widgets/dialogs/in_app_debug_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AppErrorReporter {
  static bool _isDebugDialogOpen = false;

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
    developer.log(
      message,
      name: source ?? 'Icarus',
      error: error,
      stackTrace: stackTrace,
      level: _developerLogLevel(level),
    );

    appProviderContainer.read(inAppDebugProvider.notifier).addLog(
          message: message,
          level: level,
          source: source,
          errorText: error?.toString(),
          stackTrace: stackTrace?.toString(),
        );
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
}
