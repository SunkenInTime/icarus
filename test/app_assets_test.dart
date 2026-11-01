import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/screenshot/capture_images.dart';
import 'package:icarus/screenshot/persistent_offscreen_renderer.dart';
import 'package:icarus/services/app_assets.dart';

// A 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // What the web engine does with no connection: the asset read comes back
  // empty and the bundle throws.
  var online = false;
  var reads = <String>[];

  setUp(() {
    online = false;
    reads = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(Uint8List.sublistView(message!));
      if (key.contains('AssetManifest')) {
        return const StandardMessageCodec().encodeMessage(<String, Object?>{});
      }
      reads.add(key);
      if (!online) return null;
      return ByteData.sublistView(
        key.endsWith('.json') ? utf8.encode('{}') : _png,
      );
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    PaintingBinding.instance.imageCache.clear();
  });

  Future<void> settle(WidgetTester tester, [Duration? wait]) async {
    await tester.pump(wait);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  bool painted(WidgetTester tester) =>
      tester.widget<RawImage>(find.byType(RawImage)).image != null;

  testWidgets('an image read that fails raises nothing and fills in by itself',
      (tester) async {
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: appAssets,
        child: Image.asset('ability.png', width: 10, height: 10),
      ),
    );
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(painted(tester), isFalse);
    expect(reads, ['ability.png']);

    await settle(tester, WaitingAssetBundle.retryDelay);
    expect(reads, hasLength(2));
    expect(tester.takeException(), isNull);

    online = true;
    await settle(tester, WaitingAssetBundle.retryDelay);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(painted(tester), isTrue);
    expect(appAssets.missing.value, isNot(contains('ability.png')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a capture stops rather than save a page missing a picture', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final renderer = PersistentOffscreenRenderer(
        targetSize: const Size(16, 16),
        pixelRatio: 1,
      );
      final page = Image.asset('placed_ability.png', width: 8, height: 8);
      await renderer.prepare(
        page,
        settleDuration: const Duration(milliseconds: 50),
      );

      await expectLater(
        renderer.capture(page),
        throwsA(isA<CaptureImagesUnavailable>()),
      );
      await renderer.dispose();
    });
  });

  testWidgets('a string that failed is read again, not remembered', (
    tester,
  ) async {
    String? text;
    unawaited(
      appAssets.loadString('sightlines.json').then((value) => text = value),
    );
    await settle(tester);
    expect(appAssets.missing.value, contains('sightlines.json'));

    online = true;
    await settle(tester, WaitingAssetBundle.retryDelay);

    expect(text, '{}');
    expect(appAssets.missing.value, isNot(contains('sightlines.json')));
  });
}
