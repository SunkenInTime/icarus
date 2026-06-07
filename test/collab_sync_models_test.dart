import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';

void main() {
  group('CloudCollabModeState', () {
    test('is enabled for authenticated, ready users', () {
      const mode = CloudCollabModeState(
        featureFlagEnabled: true,
        forceLocalFallback: false,
      );

      expect(
        mode.isCloudEnabled(
          isAuthenticated: true,
          isConvexUserReady: true,
        ),
        isTrue,
      );
    });

    test('is disabled when force-local fallback is enabled', () {
      const mode = CloudCollabModeState(
        featureFlagEnabled: true,
        forceLocalFallback: true,
      );

      expect(
        mode.isCloudEnabled(
          isAuthenticated: true,
          isConvexUserReady: true,
        ),
        isFalse,
      );
    });
  });

  group('StrategyOp model', () {
    test('serializes only populated optional fields', () {
      const op = StrategyOp(
        opId: 'op-1',
        kind: StrategyOpKind.patch,
        entityType: StrategyOpEntityType.element,
        entityPublicId: 'element-1',
        payload: {'foo': 'bar'},
      );

      final json = op.toConvexJson();

      expect(json['opId'], 'op-1');
      expect(json['kind'], 'patch');
      expect(json['entityType'], 'element');
      expect(json['entityPublicId'], 'element-1');
      expect(json['payload'], {'foo': 'bar'});
      expect(json.containsKey('pagePublicId'), isFalse);
      expect(json.containsKey('sortIndex'), isFalse);
      expect(json.containsKey('expectedRevision'), isFalse);
      expect(json.containsKey('expectedSequence'), isFalse);
    });

    test('copyWith updates expected values while preserving identity', () {
      const original = StrategyOp(
        opId: 'op-2',
        kind: StrategyOpKind.patch,
        entityType: StrategyOpEntityType.lineup,
        entityPublicId: 'lineup-1',
        pagePublicId: 'page-1',
      );

      final updated =
          original.copyWith(expectedRevision: 9, expectedSequence: 12);

      expect(updated.opId, original.opId);
      expect(updated.entityPublicId, original.entityPublicId);
      expect(updated.pagePublicId, original.pagePublicId);
      expect(updated.expectedRevision, 9);
      expect(updated.expectedSequence, 12);
    });
  });

  group('RemoteElement', () {
    test('decodes valid payload object data', () {
      const remote = RemoteElement(
        publicId: 'el-1',
        strategyPublicId: 'strat-1',
        pagePublicId: 'page-1',
        elementType: 'agent',
        payload: {
          'kind': 'agent',
          'payloadVersion': 1,
          'data': {'id': 'agent-1', 'elementType': 'agent'},
        },
        sortIndex: 0,
        revision: 1,
        deleted: false,
      );

      expect(remote.decodedPayload()['id'], 'agent-1');
      expect(remote.decodedPayload()['elementType'], 'agent');
    });

    test('returns empty map for payload without data', () {
      const remote = RemoteElement(
        publicId: 'el-2',
        strategyPublicId: 'strat-1',
        pagePublicId: 'page-1',
        elementType: 'agent',
        payload: {},
        sortIndex: 0,
        revision: 1,
        deleted: false,
      );

      expect(remote.decodedPayload(), isEmpty);
    });
  });

  group('canonical cloud JSON', () {
    test('treats equivalent objects as equal regardless of key order', () {
      final left = {
        'kind': 'text',
        'payloadVersion': 1,
        'data': {
          'id': 'text-1',
          'position': {'dx': 10, 'dy': 20.0},
          'elementType': 'text',
        },
      };
      final right = {
        'data': {
          'elementType': 'text',
          'position': {'dy': 20, 'dx': 10.0},
          'id': 'text-1',
        },
        'payloadVersion': 1.0,
        'kind': 'text',
      };

      expect(cloudJsonEquivalent(left, right), isTrue);
    });
  });

  group('remote metadata payloads', () {
    test('strategy headers and pages parse object metadata payloads', () {
      final header = RemoteStrategyHeader.fromJson({
        'publicId': 'strat-1',
        'name': 'Cloud',
        'mapData': 'ascent',
        'sequence': 1,
        'createdAt': 1,
        'updatedAt': 2,
        'themeOverridePalette': {
          'base': '#111111',
          'detail': '#222222',
          'highlight': '#333333',
        },
      });
      final page = RemotePage.fromJson({
        'publicId': 'page-1',
        'strategyPublicId': 'strat-1',
        'name': 'Page 1',
        'sortIndex': 0,
        'isAttack': true,
        'revision': 1,
        'settings': {
          'agentSize': 35.0,
          'abilitySize': 25.0,
          'useNeutralTeamColors': true,
        },
      });

      expect(header.themeOverridePalette, containsPair('base', '#111111'));
      expect(page.settings, containsPair('useNeutralTeamColors', true));
    });
  });

  group('RemoteImageAsset', () {
    test('parses R2 metadata without treating URL as durable payload', () {
      final asset = RemoteImageAsset.fromJson({
        'publicId': 'asset-1',
        'provider': 'r2',
        'uploadStatus': 'active',
        'fileExtension': '.png',
        'mimeType': 'image/png',
        'width': 1920,
        'height': 1080,
        'byteSize': 42,
        'uploadedAt': 1700000000000,
        'url': 'https://media.example.com/asset-1.png',
      });

      expect(asset.publicId, 'asset-1');
      expect(asset.provider, 'r2');
      expect(asset.uploadStatus, 'active');
      expect(asset.byteSize, 42);
      expect(
          asset.uploadedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(asset.url, startsWith('https://media.example.com/'));
    });

    test('defaults legacy Convex storage rows to active Convex assets', () {
      final asset = RemoteImageAsset.fromJson({
        'publicId': 'asset-legacy',
        'fileExtension': '.jpg',
      });

      expect(asset.provider, 'convex');
      expect(asset.uploadStatus, 'active');
      expect(asset.fileExtension, '.jpg');
    });
  });

  group('CloudImageUploadIntent', () {
    test('parses R2 upload response headers and expiration', () {
      final intent = CloudImageUploadIntent.fromJson({
        'provider': 'r2',
        'uploadId': 'upload-1',
        'objectKey': 'strategies/s/images/a.png',
        'uploadUrl': 'https://example.r2.cloudflarestorage.com/bucket/key',
        'requiredHeaders': {'Content-Type': 'image/png'},
        'expiresAt': 1700000000000,
        'maxBytes': 1024,
      });

      expect(intent.provider, 'r2');
      expect(intent.uploadId, 'upload-1');
      expect(intent.objectKey, 'strategies/s/images/a.png');
      expect(intent.requiredHeaders['Content-Type'], 'image/png');
      expect(
          intent.expiresAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(intent.maxBytes, 1024);
    });
  });

  group('RemoteStrategySnapshot helpers', () {
    final header = RemoteStrategyHeader(
      publicId: 'strat-1',
      name: 'Original',
      mapData: '{}',
      sequence: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
    );
    const page1 = RemotePage(
      publicId: 'page-1',
      strategyPublicId: 'strat-1',
      name: 'Page 1',
      sortIndex: 0,
      isAttack: true,
      revision: 1,
    );
    const page2 = RemotePage(
      publicId: 'page-2',
      strategyPublicId: 'strat-1',
      name: 'Page 2',
      sortIndex: 1,
      isAttack: false,
      revision: 1,
    );
    const element = RemoteElement(
      publicId: 'el-1',
      strategyPublicId: 'strat-1',
      pagePublicId: 'page-1',
      elementType: 'text',
      payload: {
        'kind': 'text',
        'payloadVersion': 1,
        'data': {},
      },
      sortIndex: 1,
      revision: 1,
      deleted: false,
    );
    const deletedElement = RemoteElement(
      publicId: 'el-2',
      strategyPublicId: 'strat-1',
      pagePublicId: 'page-1',
      elementType: 'text',
      payload: {
        'kind': 'text',
        'payloadVersion': 1,
        'data': {},
      },
      sortIndex: 0,
      revision: 2,
      deleted: true,
    );
    const lineup = RemoteLineup(
      publicId: 'lineup-1',
      strategyPublicId: 'strat-1',
      pagePublicId: 'page-2',
      payload: {
        'kind': 'lineupGroup',
        'payloadVersion': 1,
        'data': {},
      },
      sortIndex: 0,
      revision: 1,
      deleted: false,
    );

    RemoteStrategySnapshot snapshot() => RemoteStrategySnapshot(
          header: header,
          pages: const [page1, page2],
          elementsByPage: const {
            'page-1': [element],
          },
          lineupsByPage: const {
            'page-2': [lineup],
          },
          assetsById: const {},
        );

    test('header update preserves pages assets elements and lineups', () {
      final updated = snapshot().replaceHeader(
        RemoteStrategyHeader(
          publicId: 'strat-1',
          name: 'Updated',
          mapData: '{}',
          sequence: 2,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(3),
        ),
      );

      expect(updated.header.name, 'Updated');
      expect(updated.pages, const [page1, page2]);
      expect(updated.elementsByPage['page-1'], const [element]);
      expect(updated.lineupsByPage['page-2'], const [lineup]);
    });

    test('pages update preserves unchanged page maps and prunes removed pages',
        () {
      final updated = snapshot().replacePages(const [page1]);

      expect(updated.pages, const [page1]);
      expect(updated.elementsByPage.containsKey('page-1'), isTrue);
      expect(updated.lineupsByPage.containsKey('page-2'), isFalse);
    });

    test('strategy-level elements are grouped by page and retain deletes', () {
      final grouped = RemoteStrategySnapshot.groupElementsByPage(
        const [element, deletedElement],
      );

      expect(grouped['page-1'], const [deletedElement, element]);
      expect(grouped['page-1']!.first.deleted, isTrue);
    });

    test('strategy-level lineups are grouped by page', () {
      final grouped = RemoteStrategySnapshot.groupLineupsByPage(const [lineup]);

      expect(grouped['page-2'], const [lineup]);
    });
  });
}
