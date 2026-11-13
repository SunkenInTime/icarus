import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory tempDir;
  late String logPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('icarus-dropped-drawing-');
    logPath = path.join(tempDir.path, 'icarus_debug.log');
    await AppErrorReporter.initializePersistedLog(logPath);
  });

  tearDown(() async {
    await AppErrorReporter.flushPersistedLog();
    await tempDir.delete(recursive: true);
  });

  test('a drawing that cannot be read is reported, not dropped silently',
      () async {
    final line = Line(
      lineStart: const Offset(120, 340),
      lineEnd: const Offset(480, 360),
      color: Colors.red,
      isDotted: false,
      hasArrow: true,
      id: 'kept-line',
    );
    final saved = jsonDecode(DrawingProvider.objectToJson([line])) as List;
    final broken = Map<String, dynamic>.from(saved.single as Map)
      ..['id'] = 'broken-line'
      ..remove('lineEnd');

    final decoded =
        DrawingProvider.fromJson(jsonEncode([saved.single, broken]));
    await AppErrorReporter.flushPersistedLog();

    expect(decoded.map((drawing) => drawing.id), ['kept-line']);
    final log = await File(logPath).readAsString();
    expect(log, contains('ERROR [DrawingProvider.fromJson]'));
    expect(
      log,
      contains("A drawing couldn't be read and was left off the page "
          '(drawing 2 of 2, type lineDrawing).'),
    );
    expect(log, contains('Stack trace:'));
  });
}
