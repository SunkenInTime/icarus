import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart' show RemoteImageAsset;
import 'package:icarus/collab/convex_strategy_repository.dart';

Map<String, Object?> _wire(RemoteImageAsset asset) => {
      'publicId': asset.publicId,
      'provider': asset.provider,
      'uploadStatus': asset.uploadStatus,
      'fileExtension': asset.fileExtension,
      'mimeType': asset.mimeType,
      'width': asset.width,
      'height': asset.height,
      'byteSize': asset.byteSize,
      'uploadedAt': asset.uploadedAt?.millisecondsSinceEpoch,
      'url': asset.url,
      'legacyStoragePath': asset.legacyStoragePath,
    };

Future<List<String>> pageAssetLines(ProviderContainer c, String tag) async {
  final repository = c.read(convexStrategyRepositoryProvider);
  final strategies = {
    ...(await repository.fetchInventory()).strategies.keys,
    for (final entry in await repository.fetchSharedStrategies())
      entry.strategy.id,
  };
  final lines = <String>[];
  final providers = <String, int>{};
  for (final strategyId in strategies) {
    final shell = await repository.fetchShell(strategyId);
    for (final page in shell.pages) {
      final snapshot = await repository.fetchPageSnapshotAs(
        strategyPublicId: strategyId,
        pagePublicId: page.publicId,
        shareToken: null,
        accountSubject: null,
      );
      for (final MapEntry(key: id, value: asset)
          in snapshot.assetsById.entries) {
        providers.update(asset.provider, (n) => n + 1, ifAbsent: () => 1);
        lines.add('ASSET $tag strategy=$strategyId page=${page.publicId} '
            'id=$id ${jsonEncode(_wire(asset))}');
      }
    }
  }
  lines.add('ASSET $tag ${strategies.length} strategies, pictures by '
      'provider: ${providers.isEmpty ? 'none' : providers}');
  return lines;
}
