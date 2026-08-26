import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';

void main() {
  group('CloudCollabModeState', () {
    test('is enabled only for authenticated, ready users', () {
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
      expect(
        mode.isCloudEnabled(
          isAuthenticated: false,
          isConvexUserReady: true,
        ),
        isFalse,
      );
    });

    test('force-local fallback wins over auth', () {
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

  group('StrategyOp protocol', () {
    test('serializes record revision without a global sequence', () {
      const op = StrategyOp(
        opId: 'op-1',
        kind: StrategyOpKind.patch,
        entityType: StrategyOpEntityType.pageContent,
        entityPublicId: 'page-1',
        payload: {'settings': <String, dynamic>{}},
        expectedRevision: 4,
      );

      final json = op.toConvexJson();
      expect(currentCloudProtocolVersion, 2);
      expect(json['entityType'], 'pageContent');
      expect(json['expectedRevision'], 4);
      expect(json.containsKey('expectedSequence'), isFalse);
      expect(StrategyOp.fromJson(json).entityType,
          StrategyOpEntityType.pageContent);
    });

    test('copyWith preserves identity', () {
      const original = StrategyOp(
        opId: 'op-2',
        kind: StrategyOpKind.patch,
        entityType: StrategyOpEntityType.lineup,
        entityPublicId: 'lineup-1',
        pagePublicId: 'page-1',
      );
      final updated = original.copyWith(expectedRevision: 9);
      expect(updated.opId, original.opId);
      expect(updated.entityPublicId, original.entityPublicId);
      expect(updated.expectedRevision, 9);
    });
  });

  test('canonical JSON ignores key order and numeric representation', () {
    final left = {
      'data': {
        'position': {'dx': 10, 'dy': 20.0},
      },
    };
    final right = {
      'data': {
        'position': {'dy': 20, 'dx': 10.0},
      },
    };
    expect(cloudJsonEquivalent(left, right), isTrue);
  });

  test('RemoteElement decodes the canonical data envelope', () {
    const remote = RemoteElement(
      publicId: 'el-1',
      strategyPublicId: 'strat-1',
      pagePublicId: 'page-1',
      elementType: 'agent',
      payload: {
        'kind': 'agent',
        'payloadVersion': 1,
        'data': {'id': 'agent-1'},
      },
      sortIndex: 0,
      revision: 1,
      deleted: false,
    );
    expect(remote.decodedPayload()['id'], 'agent-1');
  });

  test('cloud payload data normalizes nested bridge maps for lineup parsing',
      () {
    final payload = <String, dynamic>{
      'kind': 'lineupGroup',
      'payloadVersion': 1,
      'data': <Object?, Object?>{
        'id': 'lineup-1',
        'agent': <Object?, Object?>{
          'id': 'agent-1',
          'position': <Object?, Object?>{'dx': 10, 'dy': 20},
          'type': 'sova',
          'isAlly': true,
          'state': 'none',
          'lineUpID': 'lineup-1',
        },
        'items': <Object?>[
          <Object?, Object?>{
            'id': 'item-1',
            'ability': <Object?, Object?>{
              'id': 'ability-1',
              'data': <Object?, Object?>{'type': 'sova', 'index': 2},
              'position': <Object?, Object?>{'dx': 30, 'dy': 40},
              'lineUpID': 'lineup-1',
            },
            'youtubeLink': '',
            'notes': 'proof',
            'images': <Object?>[],
          },
        ],
      },
    };

    final group = LineUpGroup.fromJson(cloudPayloadData(payload));

    expect(group.id, 'lineup-1');
    expect(group.items.single.notes, 'proof');
  });

  group('separate remote read models', () {
    final header = RemoteStrategyHeader.fromJson({
      'publicId': 'strat-1',
      'name': 'Cloud',
      'mapData': 'ascent',
      'revision': 3,
      'createdAt': 1,
      'updatedAt': 2,
      'themeOverridePalette': {'base': '#111111'},
    });
    final page = RemotePage.fromJson({
      'publicId': 'page-1',
      'strategyPublicId': 'strat-1',
      'name': 'Page 1',
      'sortIndex': 0,
      'isAttack': true,
      'revision': 2,
      'createdAt': 1,
      'updatedAt': 2,
    });
    final content = RemotePageContent.fromJson({
      'settings': {'agentSize': 35.0},
      'revision': 7,
      'createdAt': 1,
      'updatedAt': 2,
    });

    test('shell carries descriptors but no page content', () {
      final shell = RemoteStrategyShell(header: header, pages: [page]);
      expect(shell.header.revision, 3);
      expect(shell.pages.single.revision, 2);
      expect(
          shell.header.themeOverridePalette, containsPair('base', '#111111'));
    });

    test('editor carries exactly one active page body', () {
      final editor = RemoteEditorSnapshot(
        shell: RemoteStrategyShell(header: header, pages: [page]),
        activePage: RemotePageSnapshot(
          page: page,
          content: content,
          elements: const [],
          lineups: const [],
          assetsById: const {},
        ),
      );
      expect(
          editor.activePage!.content.settings, containsPair('agentSize', 35));
      expect(editor.elementsByPage.keys, ['page-1']);
    });

    test('full snapshot groups every page for one-shot export', () {
      const element = RemoteElement(
        publicId: 'el-1',
        strategyPublicId: 'strat-1',
        pagePublicId: 'page-1',
        elementType: 'text',
        payload: {'kind': 'text', 'payloadVersion': 1, 'data': {}},
        sortIndex: 1,
        revision: 1,
        deleted: false,
      );
      final grouped = RemoteFullStrategySnapshot.groupElementsByPage(
        const [element],
      );
      expect(grouped['page-1'], const [element]);
    });
  });

  group('RemoteImageAsset', () {
    test('parses R2 metadata', () {
      final asset = RemoteImageAsset.fromJson({
        'publicId': 'asset-1',
        'provider': 'r2',
        'uploadStatus': 'active',
        'fileExtension': '.png',
        'byteSize': 42,
        'uploadedAt': 1700000000000,
        'url': 'https://media.example.com/asset-1.png',
      });
      expect(asset.provider, 'r2');
      expect(asset.byteSize, 42);
    });
  });

  test('CloudImageUploadIntent parses upload headers', () {
    final intent = CloudImageUploadIntent.fromJson({
      'provider': 'r2',
      'uploadId': 'upload-1',
      'objectKey': 'strategies/s/images/a.png',
      'uploadUrl': 'https://example.invalid/key',
      'requiredHeaders': {'Content-Type': 'image/png'},
      'expiresAt': 1700000000000,
      'maxBytes': 1024,
    });
    expect(intent.requiredHeaders['Content-Type'], 'image/png');
    expect(intent.maxBytes, 1024);
  });
}
