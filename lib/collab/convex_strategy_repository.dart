import 'dart:async';

import 'package:convex_flutter/convex_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_payload.dart';

final convexStrategyRepositoryProvider = Provider<ConvexStrategyRepository>(
  (ref) => ConvexStrategyRepository(ConvexClient.instance),
);

class ConvexStrategyRepository {
  ConvexStrategyRepository(this._client);

  final ConvexClient _client;

  Stream<List<CloudFolderSummary>> watchFoldersForParent(
    String? parentFolderPublicId,
  ) {
    final controller = StreamController<List<CloudFolderSummary>>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        subscription = await _client.subscribe(
          name: 'folders:listForParent',
          args: {
            if (parentFolderPublicId != null)
              'parentFolderPublicId': parentFolderPublicId,
          },
          onUpdate: (value) {
            final raw = decodeConvexList(value);
            final mapped = raw
                .whereType<Map>()
                .map((item) => CloudFolderSummary.fromJson(
                    Map<String, dynamic>.from(item)))
                .toList(growable: false);
            controller.add(mapped);
          },
          onError: (message, value) {
            controller
                .addError(Exception('folders:listForParent error: $message'));
          },
        );
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
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
        subscription = await _client.subscribe(
          name: 'strategies:listForFolder',
          args: {
            if (folderPublicId != null) 'folderPublicId': folderPublicId,
          },
          onUpdate: (value) {
            final raw = decodeConvexList(value);
            final mapped = raw
                .whereType<Map>()
                .map((item) => CloudStrategySummary.fromJson(
                    Map<String, dynamic>.from(item)))
                .toList(growable: false);
            controller.add(mapped);
          },
          onError: (message, value) {
            controller.addError(
                Exception('strategies:listForFolder error: $message'));
          },
        );
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
    }

    start();

    controller.onCancel = () {
      try {
        subscription?.cancel();
      } catch (_) {}
    };

    return controller.stream;
  }

  Future<List<CloudFolderSummary>> fetchFolderPath(
      String? folderPublicId) async {
    if (folderPublicId == null) {
      return const [];
    }

    final response = await _client.query('folders:getPath', {
      'folderPublicId': folderPublicId,
    });

    return decodeConvexList(response)
        .whereType<Map>()
        .map((item) => CloudFolderSummary.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList(growable: false);
  }

  Stream<RemoteStrategyHeader> watchStrategyHeader(String strategyPublicId) {
    final controller = StreamController<RemoteStrategyHeader>.broadcast();
    dynamic subscription;

    Future<void> start() async {
      try {
        subscription = await _client.subscribe(
          name: 'strategies:getHeader',
          args: {'strategyPublicId': strategyPublicId},
          onUpdate: (value) {
            controller.add(
              RemoteStrategyHeader.fromJson(decodeConvexMap(value)),
            );
          },
          onError: (message, value) {
            controller
                .addError(Exception('strategies:getHeader error: $message'));
          },
        );
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      }
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
    final header = RemoteStrategyHeader.fromJson(decodeConvexMap(headerRaw));

    final pagesRaw = await _client.query('pages:listForStrategy', {
      'strategyPublicId': strategyPublicId,
    });

    final pages = decodeConvexList(pagesRaw)
        .whereType<Map>()
        .map((item) => RemotePage.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false)
      ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));

    final elementsByPage = <String, List<RemoteElement>>{};
    final lineupsByPage = <String, List<RemoteLineup>>{};

    for (final page in pages) {
      final elementsRaw = await _client.query('elements:listForPage', {
        'strategyPublicId': strategyPublicId,
        'pagePublicId': page.publicId,
      });
      final elements = decodeConvexList(elementsRaw)
          .whereType<Map>()
          .map(
              (item) => RemoteElement.fromJson(Map<String, dynamic>.from(item)))
          .toList(growable: false)
        ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
      elementsByPage[page.publicId] = elements;

      final lineupsRaw = await _client.query('lineups:listForPage', {
        'strategyPublicId': strategyPublicId,
        'pagePublicId': page.publicId,
      });
      final lineups = decodeConvexList(lineupsRaw)
          .whereType<Map>()
          .map((item) => RemoteLineup.fromJson(Map<String, dynamic>.from(item)))
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

    final decodedResponse = decodeConvexMap(response);
    final resultList = (decodedResponse['results'] as List?) ?? const [];
    return resultList
        .whereType<Map>()
        .map((item) => OpAck.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  Future<void> createFolder({
    required String publicId,
    required String name,
    String? parentFolderPublicId,
    int? iconIndex,
    String? colorKey,
    int? customColorValue,
  }) async {
    await _client.mutation(
      name: 'folders:create',
      args: {
        'publicId': publicId,
        'name': name,
        if (parentFolderPublicId != null)
          'parentFolderPublicId': parentFolderPublicId,
        if (iconIndex != null) 'iconIndex': iconIndex,
        if (colorKey != null) 'colorKey': colorKey,
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
