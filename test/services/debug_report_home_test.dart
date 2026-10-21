import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';

DebugLogEntry _entry(String message, {String? error}) => DebugLogEntry(
      timestamp: DateTime(2026, 10, 21),
      level: DebugLogLevel.info,
      message: message,
      errorText: error,
    );

void main() {
  final home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME']!;
  final separator = Platform.pathSeparator;

  test('the copied report writes the home folder as ~', () {
    AppErrorReporter.setApplicationSupportDirectoryPath(
      '$home${separator}AppData${separator}icarus',
    );
    final report = AppErrorReporter.buildClipboardReport([
      _entry('Opening $home${separator}Documents${separator}B site.ica'),
      _entry(
        'Import failed.',
        error: 'PathNotFoundException: '
            '${home.replaceAll(r'\', '/')}/Downloads/retake.ica',
      ),
    ]);

    expect(report, isNot(contains(home)));
    expect(report, contains('~${separator}AppData${separator}icarus'));
    expect(report, contains('~${separator}Documents${separator}B site.ica'));
    expect(report, contains('~/Downloads/retake.ica'));
  });

  test('a longer folder name that starts with the home is left alone', () {
    final report = AppErrorReporter.buildClipboardReport(
        [_entry('${home}2${separator}x')]);
    expect(report, contains('${home}2${separator}x'));
  });
}
