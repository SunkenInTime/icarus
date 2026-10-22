import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory tempDir;
  late String logPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-debug-log-');
    logPath = path.join(tempDir.path, 'icarus_debug.log');
  });

  tearDown(() async {
    await AppErrorReporter.flushPersistedLog();
    await tempDir.delete(recursive: true);
  });

  const cap = AppErrorReporter.persistedLogMaxBytes;

  test('a log over the cap at launch moves aside for a fresh one', () async {
    await File('$logPath.1').writeAsString('the session before last');
    await File(logPath).writeAsString('x' * cap);

    await AppErrorReporter.initializePersistedLog(logPath);
    AppErrorReporter.reportInfo('first entry this session');
    await AppErrorReporter.flushPersistedLog();

    expect(await File('$logPath.1').length(), cap);
    final current = await File(logPath).readAsString();
    expect(current, contains('first entry this session'));
    expect(current.length, lessThan(1000));
  });

  test('a log under the cap at launch keeps growing', () async {
    await File(logPath).writeAsString('earlier session\n');

    await AppErrorReporter.initializePersistedLog(logPath);
    AppErrorReporter.reportInfo('next entry');
    await AppErrorReporter.flushPersistedLog();

    expect(File('$logPath.1').existsSync(), isFalse);
    final current = await File(logPath).readAsString();
    expect(current, startsWith('earlier session'));
    expect(current, contains('next entry'));
  });

  test('a session that writes past the cap moves the log aside', () async {
    await AppErrorReporter.initializePersistedLog(logPath);
    final message = 'y' * 100000;
    for (var i = 0; i < cap ~/ 100000 + 2; i++) {
      AppErrorReporter.reportInfo('$i $message');
    }
    await AppErrorReporter.flushPersistedLog();

    final previous = await File('$logPath.1').length();
    final current = await File(logPath).length();
    expect(previous, lessThanOrEqualTo(cap));
    expect(current, lessThanOrEqualTo(cap));
    expect(previous + current, greaterThan(cap));
    expect(
        await File(logPath).readAsString(), contains('${cap ~/ 100000 + 1} '));
  });

  test('a log that cannot move keeps the previous one', () async {
    await File('$logPath.1').writeAsString('the session before last');
    await File(logPath).writeAsString('x' * cap);
    // Windows refuses to move a file another handle holds open.
    final held = await File(logPath).open(mode: FileMode.append);
    addTearDown(held.close);

    await AppErrorReporter.initializePersistedLog(logPath);
    AppErrorReporter.reportInfo('still logged');
    await AppErrorReporter.flushPersistedLog();

    expect(await File('$logPath.1').readAsString(), 'the session before last');
    expect(await File(logPath).readAsString(), contains('still logged'));
  }, skip: !Platform.isWindows);
}
