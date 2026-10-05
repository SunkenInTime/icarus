import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class _RecordingImageProvider extends PlacedImageProvider {
  final List<String> locallySavedImageIds = [];

  @override
  Future<void> saveSecureImage(
    Uint8List imageBytes,
    String imageID,
    String fileExtenstion, {
    required String? strategyId,
  }) async {
    locallySavedImageIds.add(imageID);
  }
}

class _FailingMediaQueue extends CloudMediaUploadQueueNotifier {
  bool enqueueAttempted = false;

  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );

  @override
  Future<void> enqueuePlacedImageUpload({
    required String imagePublicId,
    String? strategyPublicId,
    String? fileExtension,
    String? mimeType,
    int? width,
    int? height,
  }) async {
    enqueueAttempted = true;
    throw StateError('outbox write failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CoordinateSystem(playAreaSize: const Size(1920, 1080));

  test('failed media outbox write keeps the local source and fails closed',
      () async {
    final imageProvider = _RecordingImageProvider();
    final mediaQueue = _FailingMediaQueue();
    final container = ProviderContainer(
      overrides: [
        placedImageProvider.overrideWith(() => imageProvider),
        cloudMediaUploadQueueProvider.overrideWith(() => mediaQueue),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(placedImageProvider.notifier).addImage(
            imageBytes: Uint8List.fromList([1, 2, 3]),
            strategyId: 'strategy-a',
            strategySource: StrategySource.cloud,
            fileExtension: '.png',
            aspectRatio: 1,
          ),
      throwsA(isA<StateError>()),
    );

    expect(mediaQueue.enqueueAttempted, isTrue);
    expect(imageProvider.locallySavedImageIds, hasLength(1));
    expect(container.read(placedImageProvider).images, isEmpty);
  });
}
