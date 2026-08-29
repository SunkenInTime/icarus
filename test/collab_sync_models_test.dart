import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/json_converters.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/strategy/strategy_import_export.dart';

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
      const op = PageContentPatchOp(
        opId: 'op-1',
        pagePublicId: 'page-1',
        settings: <String, dynamic>{},
        expectedPageContentRevision: 4,
      );

      final json = op.toConvexJson();
      expect(currentCloudProtocolVersion, 3);
      expect(json['type'], 'pageContent.patch');
      expect(json['expectedPageContentRevision'], 4);
      expect(json.containsKey('expectedSequence'), isFalse);
      expect(StrategyOp.fromJson(json), isA<PageContentPatchOp>());
    });

    test('withOpId changes identity without changing typed intent', () {
      const original = LineupPatchOp(
        opId: 'op-2',
        lineupPublicId: 'lineup-1',
        pagePublicId: 'page-1',
        expectedLineupRevision: 3,
      );
      final updated = original.withOpId('op-3');
      expect(updated.opId, 'op-3');
      expect(updated.entityPublicId, original.entityPublicId);
      expect(updated.expectedRevision, 3);
      expect(updated.type, StrategyOpType.lineupPatch);
    });

    test('every operation emits only its protocol-v3 fields', () {
      const payload = <String, dynamic>{'value': 1};
      const ops = <StrategyOp>[
        StrategyPatchOp(
          opId: '1',
          payload: payload,
          expectedStrategyRevision: 1,
        ),
        PageAddOp(
          opId: '2',
          pagePublicId: 'page',
          payload: payload,
          sortIndex: 2,
          expectedStrategyRevision: 1,
        ),
        PagePatchOp(
          opId: '3',
          pagePublicId: 'page',
          payload: payload,
          expectedPageRevision: 3,
        ),
        PageDeleteOp(
          opId: '4',
          pagePublicId: 'page',
          expectedStrategyRevision: 4,
        ),
        PageReorderOp(
          opId: '5',
          pagePublicId: 'page',
          sortIndex: 5,
          expectedStrategyRevision: 4,
        ),
        PageContentPatchOp(
          opId: '6',
          pagePublicId: 'page',
          settings: payload,
          expectedPageContentRevision: 6,
        ),
        ElementAddOp(
          opId: '7',
          elementPublicId: 'element',
          pagePublicId: 'page',
          payload: payload,
          sortIndex: 7,
        ),
        ElementPatchOp(
          opId: '8',
          elementPublicId: 'element',
          pagePublicId: 'other-page',
          payload: payload,
          sortIndex: 8,
          expectedElementRevision: 8,
        ),
        ElementDeleteOp(
          opId: '9',
          elementPublicId: 'element',
          pagePublicId: 'page',
          expectedElementRevision: 9,
        ),
        ElementReorderOp(
          opId: '10',
          elementPublicId: 'element',
          pagePublicId: 'page',
          sortIndex: 10,
          expectedElementRevision: 10,
        ),
        LineupAddOp(
          opId: '11',
          lineupPublicId: 'lineup',
          pagePublicId: 'page',
          payload: payload,
          sortIndex: 11,
        ),
        LineupPatchOp(
          opId: '12',
          lineupPublicId: 'lineup',
          pagePublicId: 'other-page',
          payload: payload,
          sortIndex: 12,
          expectedLineupRevision: 12,
        ),
        LineupDeleteOp(
          opId: '13',
          lineupPublicId: 'lineup',
          pagePublicId: 'page',
          expectedLineupRevision: 13,
        ),
        LineupReorderOp(
          opId: '14',
          lineupPublicId: 'lineup',
          pagePublicId: 'page',
          sortIndex: 14,
          expectedLineupRevision: 14,
        ),
      ];
      const expected = <Map<String, dynamic>>[
        {
          'opId': '1',
          'type': 'strategy.patch',
          'payload': payload,
          'expectedStrategyRevision': 1,
        },
        {
          'opId': '2',
          'type': 'page.add',
          'pagePublicId': 'page',
          'payload': payload,
          'sortIndex': 2,
          'expectedStrategyRevision': 1,
        },
        {
          'opId': '3',
          'type': 'page.patch',
          'pagePublicId': 'page',
          'payload': payload,
          'expectedPageRevision': 3,
        },
        {
          'opId': '4',
          'type': 'page.delete',
          'pagePublicId': 'page',
          'expectedStrategyRevision': 4,
        },
        {
          'opId': '5',
          'type': 'page.reorder',
          'pagePublicId': 'page',
          'sortIndex': 5,
          'expectedStrategyRevision': 4,
        },
        {
          'opId': '6',
          'type': 'pageContent.patch',
          'pagePublicId': 'page',
          'settings': payload,
          'expectedPageContentRevision': 6,
        },
        {
          'opId': '7',
          'type': 'element.add',
          'elementPublicId': 'element',
          'pagePublicId': 'page',
          'payload': payload,
          'sortIndex': 7,
        },
        {
          'opId': '8',
          'type': 'element.patch',
          'elementPublicId': 'element',
          'pagePublicId': 'other-page',
          'payload': payload,
          'sortIndex': 8,
          'expectedElementRevision': 8,
        },
        {
          'opId': '9',
          'type': 'element.delete',
          'elementPublicId': 'element',
          'pagePublicId': 'page',
          'expectedElementRevision': 9,
        },
        {
          'opId': '10',
          'type': 'element.reorder',
          'elementPublicId': 'element',
          'pagePublicId': 'page',
          'sortIndex': 10,
          'expectedElementRevision': 10,
        },
        {
          'opId': '11',
          'type': 'lineup.add',
          'lineupPublicId': 'lineup',
          'pagePublicId': 'page',
          'payload': payload,
          'sortIndex': 11,
        },
        {
          'opId': '12',
          'type': 'lineup.patch',
          'lineupPublicId': 'lineup',
          'pagePublicId': 'other-page',
          'payload': payload,
          'sortIndex': 12,
          'expectedLineupRevision': 12,
        },
        {
          'opId': '13',
          'type': 'lineup.delete',
          'lineupPublicId': 'lineup',
          'pagePublicId': 'page',
          'expectedLineupRevision': 13,
        },
        {
          'opId': '14',
          'type': 'lineup.reorder',
          'lineupPublicId': 'lineup',
          'pagePublicId': 'page',
          'sortIndex': 14,
          'expectedLineupRevision': 14,
        },
      ];

      for (var index = 0; index < ops.length; index += 1) {
        final json = ops[index].toConvexJson();
        expect(json, expected[index]);
        expect(json, isNot(contains('kind')));
        expect(json, isNot(contains('entityType')));
        expect(StrategyOp.fromJson(json).toConvexJson(), json);
      }
    });
  });

  group('closed operation results', () {
    test('decodes applied, noop, rejected, and failed variants', () {
      expect(
        OpAck.fromJson({
          'opId': 'applied',
          'status': 'applied',
          'appliedRevision': 2,
        }),
        isA<AppliedOpAck>(),
      );
      expect(
        OpAck.fromJson({
          'opId': 'noop',
          'status': 'noop',
          'currentRevision': 3,
        }),
        isA<NoopOpAck>(),
      );
      final rejected = OpAck.fromJson({
        'opId': 'rejected',
        'status': 'rejected',
        'reason': 'revision_mismatch',
        'current': {
          'type': 'page',
          'revision': 4,
          'value': {'name': 'Current', 'isAttack': true, 'sortIndex': 0},
        },
      });
      expect(rejected, isA<RejectedOpAck>());
      expect(rejected.latestRevision, 4);
      expect(rejected.latestPayload?['name'], 'Current');
      final failed = OpAck.fromJson({
        'opId': 'failed',
        'status': 'failed',
        'code': 'INTERNAL_ERROR',
        'rawCode': 'NEW_SERVER_CODE',
        'message': 'Server failed safely',
      });
      expect(failed, isA<FailedOpAck>());
      expect((failed as FailedOpAck).rawCode, 'NEW_SERVER_CODE');
      expect(failed.isAck, isFalse);
    });

    test('decodes every closed rejection reason', () {
      for (final reason in OpRejectionReason.values) {
        final result = OpAck.fromJson({
          'opId': reason.name,
          'status': 'rejected',
          'reason': reason.wireName,
        });
        expect((result as RejectedOpAck).rejectionReason, reason);
      }
    });

    test('rejects unknown result and current-snapshot discriminators', () {
      expect(
        () => OpAck.fromJson({'opId': 'x', 'status': 'future'}),
        throwsFormatException,
      );
      expect(
        () => OpAck.fromJson({
          'opId': 'x',
          'status': 'rejected',
          'reason': 'revision_mismatch',
          'current': {'type': 'future', 'revision': 1, 'value': {}},
        }),
        throwsFormatException,
      );
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
              'data': <Object?, Object?>{'type': 'sova', 'index': 2.0},
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

  test('ability info accepts Convex float64 integers and rejects fractions',
      () {
    const converter = AbilityInfoConverter();

    expect(
      converter.fromJson(<String, dynamic>{
        'type': 'sova',
        'index': 2.0,
      }).index,
      2,
    );
    expect(
      () => converter.fromJson(<String, dynamic>{
        'type': 'sova',
        'index': 2.5,
      }),
      throwsFormatException,
    );
  });

  test('cloud export fails closed instead of dropping a malformed lineup', () {
    final now = DateTime.utc(2026, 8, 29);
    const strategyId = 'strategy-1';
    const pageId = 'page-1';
    final snapshot = RemoteFullStrategySnapshot(
      header: RemoteStrategyHeader(
        publicId: strategyId,
        name: 'Cloud strategy',
        mapData: 'ascent',
        revision: 1,
        createdAt: now,
        updatedAt: now,
      ),
      pages: [
        RemoteFullPage(
          page: RemotePage(
            publicId: pageId,
            strategyPublicId: strategyId,
            name: 'Page 1',
            sortIndex: 0,
            isAttack: true,
            revision: 1,
            createdAt: now,
            updatedAt: now,
          ),
          content: RemotePageContent(
            revision: 1,
            createdAt: now,
            updatedAt: now,
          ),
        ),
      ],
      elementsByPage: const <String, List<RemoteElement>>{},
      lineupsByPage: const <String, List<RemoteLineup>>{
        pageId: [
          RemoteLineup(
            publicId: 'lineup-1',
            strategyPublicId: strategyId,
            pagePublicId: pageId,
            payload: <String, dynamic>{'invalid': true},
            sortIndex: 0,
            revision: 1,
            deleted: false,
          ),
        ],
      },
      assetsById: const <String, RemoteImageAsset>{},
    );

    expect(
      () => StrategyImportExportService.strategyDataFromRemoteSnapshotForTest(
          snapshot),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Cloud lineup lineup-1 could not be exported'),
        ),
      ),
    );
  });

  group('separate remote read models', () {
    final header = RemoteStrategyHeader(
      publicId: 'strat-1',
      name: 'Cloud',
      mapData: 'ascent',
      revision: 3,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
      themeOverridePalette: const {'base': '#111111'},
    );
    final page = RemotePage(
      publicId: 'page-1',
      strategyPublicId: 'strat-1',
      name: 'Page 1',
      sortIndex: 0,
      isAttack: true,
      revision: 2,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
    );
    final content = RemotePageContent(
      settings: const {'agentSize': 35.0},
      revision: 7,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2),
    );

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
    test('retains typed R2 metadata', () {
      final asset = RemoteImageAsset(
        publicId: 'asset-1',
        provider: 'r2',
        uploadStatus: 'active',
        fileExtension: '.png',
        width: null,
        height: null,
        byteSize: 42,
        uploadedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        url: 'https://media.example.com/asset-1.png',
        legacyStoragePath: null,
      );
      expect(asset.provider, 'r2');
      expect(asset.byteSize, 42);
    });
  });

  test('CloudImageUploadIntent retains typed upload headers', () {
    final intent = CloudImageUploadIntent(
      provider: 'r2',
      uploadId: 'upload-1',
      objectKey: 'strategies/s/images/a.png',
      uploadUrl: 'https://example.invalid/key',
      requiredHeaders: const {'Content-Type': 'image/png'},
      expiresAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      maxBytes: 1024,
    );
    expect(intent.requiredHeaders['Content-Type'], 'image/png');
    expect(intent.maxBytes, 1024);
  });
}
