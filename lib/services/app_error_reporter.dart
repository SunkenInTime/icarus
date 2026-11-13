import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show
        DiagnosticLevel,
        FlutterErrorDetails,
        debugPrint,
        defaultTargetPlatform,
        kIsWeb,
        visibleForTesting;
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/services/debug_breadcrumbs.dart';
import 'package:icarus/widgets/dialogs/in_app_debug_dialog.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AppErrorReporter {
  static const Duration _interactiveNotificationCooldown = Duration(
    seconds: 3,
  );
  static const Duration _interactiveNotificationRetention = Duration(
    minutes: 2,
  );

  /// Whether warnings and errors are also printed to the console. On web,
  /// `developer.log` does not reach the browser console in a release build,
  /// so without this a failure there leaves no trace. Messages are already
  /// redacted by their callers, as they are for the copyable debug report.
  static bool echoToConsole = kIsWeb;

  /// How large the persisted log grows before it moves to `<name>.1`,
  /// replacing the one there, and a fresh log starts. Together the two
  /// stay near twice this, unless the log can't be moved (another copy of
  /// the app holds it open) or a single entry is bigger than the cap.
  static const int persistedLogMaxBytes = 1024 * 1024;

  static bool _isDebugDialogOpen = false;
  static File? _persistedLogFile;
  static int _persistedLogBytes = 0;
  static String? _applicationSupportDirectoryPath;
  static Future<void> _persistedLogWriteQueue = Future.value();
  static final Map<String, _InteractiveNotificationState>
      _interactiveNotificationStates = {};

  /// Lines for the debug report's header about the session right now:
  /// signed in or not, the open strategy, the screen. Set by main, which
  /// can read the providers; never the user's name, email or content.
  static List<String> Function()? describeSession;

  static Future<void> initializePersistedLog(String logFilePath) async {
    final logFile = File(logFilePath);

    try {
      await logFile.parent.create(recursive: true);
      if (!await logFile.exists()) {
        await logFile.create(recursive: true);
      }
      _persistedLogBytes = await logFile.length();
      if (_persistedLogBytes >= persistedLogMaxBytes) {
        await _rotatePersistedLog(logFile);
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

  static void setApplicationSupportDirectoryPath(String directoryPath) {
    final normalizedPath = directoryPath.trim();
    if (normalizedPath.isEmpty ||
        normalizedPath == _applicationSupportDirectoryPath) {
      return;
    }

    _applicationSupportDirectoryPath = normalizedPath;
    reportInfo(
      'Application support directory: $normalizedPath',
      source: 'AppErrorReporter.environment',
    );
  }

  static String? get applicationSupportDirectoryPath =>
      _applicationSupportDirectoryPath;

  static String? get persistedLogPath => _persistedLogFile?.path;

  /// Waits for every queued write to the persisted log.
  @visibleForTesting
  static Future<void> flushPersistedLog() => _persistedLogWriteQueue;

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
    String? toastMessage,
  }) {
    final entry = addDebugLog(
      message,
      level: DebugLogLevel.warning,
      source: source,
      error: error,
      stackTrace: stackTrace,
    );

    if (promptUser) {
      _showInteractiveNotificationIfNeeded(entry, toastMessage);
    }
  }

  static void reportError(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? source,
    bool promptUser = true,
    String? toastMessage,
  }) {
    final entry = addDebugLog(
      message,
      level: DebugLogLevel.error,
      source: source,
      error: error,
      stackTrace: stackTrace,
      recentActivity: DebugBreadcrumbs.describe(),
    );

    if (promptUser) {
      _showInteractiveNotificationIfNeeded(entry, toastMessage);
    }
  }

  static DebugLogEntry addDebugLog(
    String message, {
    DebugLogLevel level = DebugLogLevel.info,
    String? source,
    Object? error,
    StackTrace? stackTrace,
    String? recentActivity,
  }) {
    final errorText = error?.toString();
    final entry = DebugLogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
      source: source,
      errorText: errorText,
      stackTrace: stackTrace?.toString(),
      recentActivity: recentActivity,
    );

    developer.log(
      message,
      name: source ?? 'Icarus',
      error: error,
      stackTrace: stackTrace,
      level: _developerLogLevel(level),
    );
    if (echoToConsole && level != DebugLogLevel.info) {
      debugPrint(
        '[${source ?? 'Icarus'}] ${level.name}: $message'
        '${errorText == null ? '' : ': $errorText'}',
      );
    }

    try {
      appProviderContainer.read(inAppDebugProvider.notifier).addEntry(entry);
    } catch (_) {
      // Tests and early startup can report logs before the global container exists.
    }
    _queuePersistedLogWrite(entry);
    return entry;
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

  /// Where a Flutter error happened, in Flutter's own words ("while
  /// setting text input editing state", "building TextField"), and what
  /// else it said about it, such as the widget that threw. The exception
  /// and stack go in separately.
  static String describeFlutterError(FlutterErrorDetails details) {
    final buffer = StringBuffer('A UI error occurred');
    final context = details.context?.toDescription().trim();
    if (context != null && context.isNotEmpty) buffer.write(' $context');
    buffer.write('.');
    if (details.library != null) buffer.write(' (${details.library})');
    final collector = details.informationCollector;
    if (collector != null) {
      try {
        final information = collector()
            .map(
              (node) =>
                  node.toStringDeep(minLevel: DiagnosticLevel.info).trimRight(),
            )
            .where((line) => line.isNotEmpty)
            .join('\n');
        if (information.isNotEmpty) {
          buffer
            ..writeln()
            ..write(_capped(information, 1500));
        }
      } catch (_) {
        // Describing the error must not raise another one.
      }
    }
    return buffer.toString();
  }

  static String _capped(String text, int maxLength) =>
      text.length <= maxLength ? text : '${text.substring(0, maxLength)}...';

  /// What a report needs before anything else: which build, on what.
  static List<String> _environmentLines() {
    const flutterVersion = String.fromEnvironment('FLUTTER_VERSION');
    final platform = kIsWeb
        ? 'web on ${defaultTargetPlatform.name}'
        : '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    final locales = PlatformDispatcher.instance.locales
        .map((locale) => locale.toLanguageTag())
        .join(', ');
    return [
      'App version: ${Settings.versionName} (build ${Settings.versionNumber})',
      'Platform: $platform',
      if (flutterVersion.isNotEmpty) 'Flutter: $flutterVersion',
      if (locales.isNotEmpty) 'System languages: $locales',
    ];
  }

  static List<String> _sessionLines() {
    try {
      return describeSession?.call() ?? const [];
    } catch (error) {
      return ['Session: unavailable ($error)'];
    }
  }

  static String buildClipboardReport(Iterable<DebugLogEntry> entries) {
    final entryList = entries.toList(growable: false);
    final buffer = StringBuffer()
      ..writeln('Icarus Debug Report')
      ..writeln('Generated: ${formatDebugLogTimestamp(DateTime.now())}');
    _environmentLines().forEach(buffer.writeln);
    _sessionLines().forEach(buffer.writeln);
    buffer
      ..writeln(
        'Update channel: '
        '${updateChannelLabel(kResolvedUpdateChannel)} ($kResolvedUpdateChannel)',
      )
      ..writeln(
          'Desktop updater manifest: ${Settings.desktopUpdaterArchiveUrl}')
      ..writeln(
        'Application support directory: '
        '${_applicationSupportDirectoryPath ?? 'Unavailable'}',
      );
    if (_persistedLogFile != null) {
      buffer.writeln('Persisted debug log: ${_persistedLogFile!.path}');
    }
    buffer.writeln();

    if (entryList.isEmpty) {
      buffer.writeln('No logs recorded.');
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

    final activity = DebugBreadcrumbs.describe();
    if (activity != null) {
      buffer
        ..writeln()
        ..writeln('-----')
        ..writeln()
        ..writeln('Recent activity (oldest first):')
        ..writeln(activity);
    }

    var text = buffer.toString().trimRight();
    if (!kIsWeb) {
      text = withHomeAsTilde(
        text,
        home: Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'],
        windows: Platform.isWindows,
      );
    }
    return asCodeBlock(text);
  }

  /// [text] fenced as a code block, so the chat or issue it is pasted into
  /// shows it as written. Unfenced, Discord turns `:34:` in a timestamp
  /// into an emoji and Markdown turns `_name_` into italics. A fence inside
  /// the text would end the block early, so those become plain quotes.
  @visibleForTesting
  static String asCodeBlock(String text) =>
      '```text\n${text.replaceAll('```', "'''")}\n```';

  /// [text] with the user's home folder written as `~`, so the account
  /// name in it doesn't travel with a pasted report. Covers the folder as
  /// written, with forward slashes, JSON-escaped, and in a file URI; a
  /// short 8.3 name or another spelling of the same folder isn't caught.
  @visibleForTesting
  static String withHomeAsTilde(
    String text, {
    required String? home,
    required bool windows,
  }) {
    home = home?.replaceFirst(RegExp(r'[\\/]+$'), '');
    // A home at the root of a drive would turn every path into ~.
    if (home == null || !RegExp(r'[\\/][^\\/]+$').hasMatch(home)) {
      return text;
    }
    final forward = home.replaceAll(r'\', '/');
    final forms = {
      home,
      forward,
      home.replaceAll(r'\', r'\\'),
      // As a file URI's path writes it: a space as %20, # as %23. Windows
      // paths come out as /C:/..., and a file URI puts its own / first.
      Uri.file(home, windows: windows)
          .path
          .replaceFirst(RegExp(r'^/(?=[A-Za-z]:)'), ''),
    };
    var result = text;
    // Longest first, so the JSON form isn't half-replaced by the plain one.
    for (final form in forms.toList()
      ..sort((a, b) => b.length.compareTo(a.length))) {
      // Not inside a longer folder name, like C:\Users\sam beside C:\Users\samuel.
      result = result.replaceAll(
        RegExp(
          '${RegExp.escape(form)}(?![\\w.-])',
          caseSensitive: !windows,
        ),
        '~',
      );
    }
    return result;
  }

  static bool get _canShowInteractiveUi =>
      appNavigatorKey.currentContext != null ||
      appNavigatorKey.currentState?.overlay?.context != null;

  /// Shows [toastMessage] when given, else the logged message.
  static void _showInteractiveNotificationIfNeeded(
    DebugLogEntry entry, [
    String? toastMessage,
  ]) {
    if (!_canShowInteractiveUi) return;

    final now = DateTime.now();
    _pruneInteractiveNotificationStates(now);

    final existingState = _interactiveNotificationStates[entry.dedupeKey];
    if (existingState != null &&
        now.difference(existingState.lastSeenAt) <=
            _interactiveNotificationCooldown) {
      existingState.lastSeenAt = now;
      return;
    }

    _interactiveNotificationStates[entry.dedupeKey] =
        (existingState ?? _InteractiveNotificationState())..lastSeenAt = now;

    Settings.showToast(
      message: toastMessage ?? entry.message,
      backgroundColor: Settings.tacticalVioletTheme.destructive,
      actionLabel: (appNavigatorKey.currentContext ??
              appNavigatorKey.currentState!.overlay!.context)
          .l10n
          .serviceMsgOpenLogs,
      onActionPressed: () {
        unawaited(openDebugLog());
      },
    );
  }

  static void _pruneInteractiveNotificationStates(DateTime now) {
    _interactiveNotificationStates.removeWhere(
      (_, state) =>
          now.difference(state.lastSeenAt) > _interactiveNotificationRetention,
    );
  }

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
    final bytes = utf8.encode(buffer.toString());

    if (_persistedLogBytes > 0 &&
        _persistedLogBytes + bytes.length > persistedLogMaxBytes) {
      await _rotatePersistedLog(logFile);
    }
    await logFile.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    _persistedLogBytes += bytes.length;
  }

  static Future<void> _rotatePersistedLog(File logFile) async {
    // The byte count is also the retry budget: a log that can't move
    // (another copy of the app has it open) keeps growing, and the next try
    // waits for another cap's worth.
    _persistedLogBytes = 0;
    try {
      // Replaces the old .1 in the same step, so a move that fails keeps it.
      await logFile.rename('${logFile.path}.1');
    } catch (error, stackTrace) {
      developer.log(
        'Failed to rotate persisted debug log.',
        name: 'AppErrorReporter._rotatePersistedLog',
        error: error,
        stackTrace: stackTrace,
        level: 900,
      );
    }
  }
}

class _InteractiveNotificationState {
  DateTime lastSeenAt = DateTime.fromMillisecondsSinceEpoch(0);
}
