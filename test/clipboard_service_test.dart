import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/clipboard_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pasteboard = MethodChannel('pasteboard');
  final picture = Uint8List.fromList([1, 2, 3]);
  final calls = <String>[];

  /// What the plugin returns for a picture: a temporary file on Windows.
  Object onClipboard() {
    if (!Platform.isWindows) return picture;
    final file = File(
      '${Directory.systemTemp.createTempSync('icarus-pasteboard-').path}/p.bmp',
    )..writeAsBytesSync(picture);
    return file.path;
  }

  void answer(Object? Function(MethodCall call) reply) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pasteboard, (
      call,
    ) async {
      calls.add(call.method);
      return reply(call);
    });
  }

  final refused =
      PlatformException(code: '0', message: 'open clipboard failed');

  setUp(calls.clear);
  tearDown(
    () => binding.defaultBinaryMessenger
        .setMockMethodCallHandler(pasteboard, null),
  );

  test('a clipboard another program holds is read once it lets go', () async {
    var refusals = 2;
    answer((_) {
      if (refusals-- > 0) throw refused;
      return onClipboard();
    });

    final image = await ClipboardService.trySelectImageFromClipboard();

    expect(image?.bytes, picture);
    expect(calls, ['image', 'image', 'image']);
  });

  test('a clipboard held past the wait is busy, not empty', () async {
    answer((_) => throw refused);

    await expectLater(
      ClipboardService.trySelectImageFromClipboard(),
      throwsA(isA<ClipboardBusyException>()),
    );
  });

  test('a picture is kept when the clipboard is busy again afterwards',
      () async {
    answer((call) {
      if (call.method == 'files') throw refused;
      return onClipboard();
    });

    final image = await ClipboardService.trySelectImageFromClipboard();

    expect(image?.bytes, picture);
    expect(calls, ['image']);
  });

  test('a clipboard with no picture is not retried', () async {
    answer((call) => call.method == 'files' ? <String>[] : null);

    expect(await ClipboardService.trySelectImageFromClipboard(), isNull);
    expect(calls, ['image', 'files']);
  });

  test('a paste waits for the clear a copy started', () async {
    final log = <String>[];
    var refusals = 2;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method != 'Clipboard.setData') return null;
        if (refusals-- > 0) throw refused;
        log.add('cleared');
        return null;
      },
    );
    addTearDown(
      () => binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    answer((call) {
      log.add(call.method);
      return call.method == 'files' ? <String>[] : null;
    });

    await Future.wait([
      ClipboardService.clear(),
      ClipboardService.readPastedImage(),
    ]);

    expect(log, ['cleared', 'image', 'files']);
  });
}
