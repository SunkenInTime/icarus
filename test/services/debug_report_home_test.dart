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
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
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
            '${home!.replaceAll(r'\', '/')}/Downloads/retake.ica',
      ),
    ]);

    expect(report, isNot(contains(home)));
    expect(report, contains('~${separator}AppData${separator}icarus'));
    expect(report, contains('~${separator}Documents${separator}B site.ica'));
    expect(report, contains('~/Downloads/retake.ica'));
  }, skip: home == null ? 'no home folder in this environment' : false);

  group('withHomeAsTilde', () {
    const home = r'C:\Users\Alex Smith';
    String redact(String text) =>
        AppErrorReporter.withHomeAsTilde(text, home: home, windows: true);

    test('covers the folder in every form a report carries', () {
      expect(redact(r'C:\Users\Alex Smith\Documents\plan.ica'),
          r'~\Documents\plan.ica');
      expect(redact('C:/Users/Alex Smith/Documents/plan.ica'),
          '~/Documents/plan.ica');
      expect(redact(r'{"path":"C:\\Users\\Alex Smith\\Documents\\plan.ica"}'),
          r'{"path":"~\\Documents\\plan.ica"}');
      expect(redact('file:///C:/Users/Alex%20Smith/Documents/plan.ica'),
          'file:///~/Documents/plan.ica');
      expect(redact(r'c:\users\alex smith\Documents'), r'~\Documents');
    });

    test('covers a file URI of a home with a # in its name', () {
      const hashHome = r'C:\Users\Alex#Smith';
      final uri =
          Uri.file(r'C:\Users\Alex#Smith\Documents\plan.ica', windows: true)
              .toString();
      expect(
        AppErrorReporter.withHomeAsTilde(uri, home: hashHome, windows: true),
        'file:///~/Documents/plan.ica',
      );
    });

    test('leaves a longer folder name that starts with the home', () {
      expect(redact(r'C:\Users\Alex Smithson\x'), r'C:\Users\Alex Smithson\x');
    });

    test('changes nothing for a home at the root of a drive', () {
      expect(
        AppErrorReporter.withHomeAsTilde(r'C:\x', home: r'C:\', windows: true),
        r'C:\x',
      );
    });
  });
}
