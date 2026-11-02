import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/services/strategy_folders.dart';
import 'package:path/path.dart' as path;

const _pathProvider = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late Directory store;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('icarus-support-');
    store = await Directory.systemTemp.createTemp('icarus-store-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, (_) async => support.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await support.delete(recursive: true);
    await store.delete(recursive: true);
  });

  // Flutter tests build without ICARUS_DRIVE, like every shipped build. Moving
  // the root here would strand the pictures users already have.
  test('a normal build given a store keeps pictures in support', () async {
    keepStrategyFoldersInDriveStore(store.path);

    final images = await PlacedImageProvider.getImageFolder('strategy-1');

    expect(images.path, path.join(support.path, 'strategy-1', 'images'));
    expect(await store.list().isEmpty, isTrue);
  });
}
