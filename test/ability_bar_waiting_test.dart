import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/app_assets.dart';
import 'package:icarus/widgets/loading_spinner.dart';
import 'package:icarus/widgets/sidebar_widgets/ability_bar.dart';

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

  setUp(() {
    online = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = utf8.decode(Uint8List.sublistView(message!));
      if (key.contains('AssetManifest')) {
        return const StandardMessageCodec().encodeMessage(<String, Object?>{});
      }
      if (!online) return null;
      return ByteData.sublistView(_png);
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
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  Future<void> pumpIcon(WidgetTester tester, String path) {
    return tester.pumpWidget(
      DefaultAssetBundle(
        bundle: appAssets,
        child: Center(
          child: SizedBox.square(dimension: 55, child: AbilityBarIcon(path)),
        ),
      ),
    );
  }

  testWidgets('an icon waiting for the connection spins, then shows',
      (tester) async {
    await pumpIcon(tester, 'offline_ability.png');
    await settle(tester);

    expect(appAssets.missing.value, contains('offline_ability.png'));
    expect(find.byType(LoadingSpinner), findsOneWidget);

    online = true;
    await settle(tester, WaitingAssetBundle.retryDelay);
    await settle(tester);

    expect(find.byType(LoadingSpinner), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });

  testWidgets('an icon that reads first time never spins', (tester) async {
    online = true;
    await pumpIcon(tester, 'online_ability.png');

    expect(find.byType(LoadingSpinner), findsNothing);
    await settle(tester);
    expect(find.byType(LoadingSpinner), findsNothing);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });
}
