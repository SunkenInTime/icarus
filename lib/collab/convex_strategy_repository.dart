import 'dart:async';
import 'dart:convert';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';

final convexStrategyRepositoryProvider = Provider<ConvexStrategyRepository>(
  (ref) => ConvexStrategyRepository(ConvexClient.instance),
);

class ConvexStrategyRepository {
  ConvexStrategyRepository(this._client);

  final ConvexClient _client;

  Object? _decodeJsonPayload(dynamic value) {
    if (value is String) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  Map<String, dynamic> _decodeObject(dynamic value) {
    final decoded = _decodeJsonPayload(value);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    throw FormatException('Expected object payload, received ${decoded.runtimeType}');
  }

  List<Map<String, dynamic>> _decodeObjectList(dynamic value) {
    final decoded = _decodeJsonPayload(value);
    if (decoded is! List) {
      throw FormatException('Expected list payload, received ${decoded.runtimeType}');
    }

    return decoded
        .map((item) => _decodeJsonPayload(item))
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Future<List<CloudFolderSummary>> listFoldersForParent(
    String? parentFolderPublicId,
  ) async {
    final response = await _client.query('folders:listForParent', {
      if (parentFolderPublicId != null)
        'parentFolderPublicId': parentFolderPublicId,
    });
    return _decodeObjectList(response)
        .map(CloudFolderSummary.fromJson)
        .toList(growable: false);
  }

  Future<List<CloudFolderSummary>> listAllFolders() async {
    final response = await _client.query('folders:listAll', {});
    return _decodeObjectList(response)
        .map(CloudFolderSummary.fromJson)
        .toList(growable: false);
  }

  Future<List<CloudStrategySummary>> listStrategiesForFolder(
    String? folderPublicId,
  ) async {
    final response = await _client.query('strategies:listForFolder', {
      if (folderPublicId != null) 'folderPublicId': folderPublicId,
    });
    return _decodeObjectList(response)
        .map(CloudStrategySummary.fromJson)
        .toList(growable: false);
  }

  Stream<List<CloudFolderSummary>> watchFoldersForParent(
    String? parentFolderPublicId,
  ) {
    final controller = StreamController<List<CloudFolderSummary>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        controller.add(await listFoldersForParent(parentFolderPublicId));
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }

      subscription = await _client.subscribe(
        name: 'folders:listForParent',
        args: {
          if (parentFolderPublicId != null)
            'parentFolderPublicId': parentFolderPublicId,
        },
        onUpdate: (value) {
          try {
            final mapped = _decodeObjectList(value)
                .map(CloudFolderSummary.fromJson)
                .toList(growable: false);
            controller.add(mapped);
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller.addError(Exception('folders:listForParent error: $message'));
        },
      );
    }

    start();
    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Stream<List<CloudStrategySummary>> watchStrategiesForFolder(
    String? folderPublicId,
  ) {
    final controller = StreamController<List<CloudStrategySummary>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        controller.add(await listStrategiesForFolder(folderPublicId));
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }

      subscription = await _client.subscribe(
        name: 'strategies:listForFolder',
        args: {
          if (folderPublicId != null) 'folderPublicId': folderPublicId,
        },
        onUpdate: (value) {
          try {
            final mapped = _decodeObjectList(value)
                .map(CloudStrategySummary.fromJson)
                .toList(growable: false);
            controller.add(mapped);
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller
              .addError(Exception('strategies:listForFolder error: $message'));
        },
      );
    }

    start();

    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Stream<RemoteStrategyHeader> watchStrategyHeader(String strategyPublicId) {
    final controller = StreamController<RemoteStrategyHeader>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      subscription = await _client.subscribe(
        name: 'strategies:getHeader',
        args: {'strategyPublicId': strategyPublicId},
        onUpdate: (value) {
          try {
            controller.add(RemoteStrategyHeader.fromJson(_decodeObject(value)));
          } catch (error, stackTrace) {
            controller.addError(error, stackTrace);
          }
        },
        onError: (message, value) {
          controller.addError(Exception('strategies:getHeader error: $message'));
        },
      );
    }

    start();
    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Future<RemoteStrategySnapshot> fetchSnapshot(String strategyPublicId) async {
    final headerRaw = await _client.query('strategies:getHeader', {
      'strategyPublicId': strategyPublicId,
    });
    final header = RemoteStrategyHeader.fromJson(_decodeObject(headerRaw));

    final pagesRaw = await _client.query('pages:listForStrategy', {
      'strategyPublicId': strategyPublicId,
    });

    final pages = _decodeObjectList(pagesRaw)
        .map(RemotePage.fromJson)
        .toList(growable: false)
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    final elementsByPage = <String, List<RemoteElement>>{};
    final lineupsByPage = <String, List<RemoteLineup>>{};

    for (final page in pages) {
      final elementsRaw = await _client.query('elements:listForPage', {
        'strategyPublicId': strategyPublicId,
        'pagePublicId': page.publicId,
      });
      final elements = _decodeObjectList(elementsRaw)
          .map(RemoteElement.fromJson)
          .toList(growable: false)
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      elementsByPage[page.publicId] = elements;

      final lineupsRaw = await _client.query('lineups:listForPage', {
        'strategyPublicId': strategyPublicId,
        'pagePublicId': page.publicId,
      });
      final lineups = _decodeObjectList(lineupsRaw)
          .map(RemoteLineup.fromJson)
          .toList(growable: false)
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      lineupsByPage[page.publicId] = lineups;
    }

    return RemoteStrategySnapshot(
      header: header,
      pages: pages,
      elementsByPage: elementsByPage,
      lineupsByPage: lineupsByPage,
    );
  }

  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    if (ops.isEmpty) {
      return const [];
    }

    final response = await _client.mutation(
      name: 'ops:applyBatch',
      args: {
        'strategyPublicId': strategyPublicId,
        'clientId': clientId,
        'ops': ops.map((op) => op.toConvexJson()).toList(growable: false),
      },
    );

    final resultList = (_decodeObject(response)['results'] as List?) ?? const [];
    return resultList
        .whereType<Map>()
        .map((item) => OpAck.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconCodePoint,
    String? iconFontFamily,
    String? iconFontPackage,
    String? color,
    int? customColorValue,
  }) async {
    await _client.mutation(
      name: 'folders:create',
      args: {
        'publicId': publicId,
        'name': name,
        if (parentFolderPublicId != null)
          'parentFolderPublicId': parentFolderPublicId,
        if (iconCodePoint != null) 'iconCodePoint': iconCodePoint,
        if (iconFontFamily != null) 'iconFontFamily': iconFontFamily,
        if (iconFontPackage != null) 'iconFontPackage': iconFontPackage,
        if (color != null) 'color': color,
        if (customColorValue != null) 'customColorValue': customColorValue,
      },
    );
  }

  Future<void> createStrategy({
    required String publicId,
    required String name,
    required String mapData,
    String? folderPublicId,
    String? themeProfileId,
    String? themeOverridePalette,
  }) async {
    await _client.mutation(
      name: 'strategies:create',
      args: {
        'publicId': publicId,
        'name': name,
        'mapData': mapData,
        if (folderPublicId != null) 'folderPublicId': folderPublicId,
        if (themeProfileId != null) 'themeProfileId': themeProfileId,
        if (themeOverridePalette != null)
          'themeOverridePalette': themeOverridePalette,
      },
    );
  }
}
