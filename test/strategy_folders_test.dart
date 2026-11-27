import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/startup/app_instance.dart';
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
    decideAppInstance(const InstalledApp());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProvider, null);
    await support.delete(recursive: true);
    await store.delete(recursive: true);
  });

  test('the installed app keeps pictures in the support folder', () async {
    decideAppInstance(const InstalledApp());

    final images = await PlacedImageProvider.getImageFolder('strategy-1');

    expect(images.path, path.join(support.path, 'strategy-1', 'images'));
  });

  test('a separate instance keeps pictures in its own folder, in any build',
      () async {
    decideAppInstance(SeparateInstance(store.path));

    final images = await PlacedImageProvider.getImageFolder('strategy-1');

    expect(images.path, path.join(store.path, 'strategy-1', 'images'));
    expect(await support.list().isEmpty, isTrue);
  });
}
