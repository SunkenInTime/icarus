import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/collab/media_bytes_source.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:path/path.dart' as path;

class _OpenStrategy extends StrategyProvider {
  _OpenStrategy(this.source);

  final StrategySource source;

  @override
  StrategyState build() => StrategyState(
        strategyId: 'strategy-1',
        strategyName: 'Strategy',
        source: source,
        isOpen: true,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDir;

  setUp(() async {
    supportDir = await Directory.systemTemp.createTemp('icarus-image-size');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => supportDir.path,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await supportDir.delete(recursive: true);
  });

  ProviderContainer desktop(StrategySource source) {
    final container = ProviderContainer(overrides: [
      imageFilesOnDeviceProvider.overrideWithValue(true),
      strategyProvider.overrideWith(() => _OpenStrategy(source)),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  File imageFile(String id) =>
      File(path.join(supportDir.path, 'strategy-1', 'images', '$id.png'));

  test(
      'a cloud strategy on desktop refuses an image over 15 MB before '
      'writing it', () async {
    final container = desktop(StrategySource.cloud);

    await expectLater(
      container.read(placedImageProvider.notifier).saveSecureImage(
            Uint8List(maxCloudImageBytes + 1),
            'too-large',
            '.png',
            strategyId: 'strategy-1',
          ),
      throwsA(
        isA<MediaTooLargeException>().having(
          (error) => error.userMessage,
          'userMessage',
          'This image is over 15 MB. Pick a smaller one.',
        ),
      ),
    );

    expect(imageFile('too-large').existsSync(), isFalse);
  });

  test('a cloud strategy on desktop keeps an image at the limit', () async {
    final container = desktop(StrategySource.cloud);

    await container.read(placedImageProvider.notifier).saveSecureImage(
          Uint8List(maxCloudImageBytes),
          'at-limit',
          '.png',
          strategyId: 'strategy-1',
        );

    expect(imageFile('at-limit').lengthSync(), maxCloudImageBytes);
  });

  test('a local strategy never uploads, so it keeps any size', () async {
    final container = desktop(StrategySource.local);

    await container.read(placedImageProvider.notifier).saveSecureImage(
          Uint8List(maxCloudImageBytes + 1),
          'local-large',
          '.png',
          strategyId: 'strategy-1',
        );

    expect(imageFile('local-large').lengthSync(), maxCloudImageBytes + 1);
  });
}
