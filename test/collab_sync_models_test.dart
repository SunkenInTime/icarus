import 'package:flutter_test/flutter_test.dart';
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
        payload: '{"foo":"bar"}',
      );

      final json = op.toConvexJson();

      expect(json['opId'], 'op-1');
      expect(json['kind'], 'patch');
      expect(json['entityType'], 'element');
      expect(json['entityPublicId'], 'element-1');
      expect(json['payload'], '{"foo":"bar"}');
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
    test('decodes valid payload json object', () {
      const remote = RemoteElement(
        publicId: 'el-1',
        strategyPublicId: 'strat-1',
        pagePublicId: 'page-1',
        elementType: 'agent',
        payload: '{"id":"agent-1","elementType":"agent"}',
        sortIndex: 0,
        revision: 1,
        deleted: false,
      );

      expect(remote.decodedPayload()['id'], 'agent-1');
      expect(remote.decodedPayload()['elementType'], 'agent');
    });

    test('returns empty map for invalid payload json', () {
      const remote = RemoteElement(
        publicId: 'el-2',
        strategyPublicId: 'strat-1',
        pagePublicId: 'page-1',
        elementType: 'agent',
        payload: 'not json',
        sortIndex: 0,
        revision: 1,
        deleted: false,
      );

      expect(remote.decodedPayload(), isEmpty);
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
      payload: '{}',
      sortIndex: 1,
      revision: 1,
      deleted: false,
    );
    const deletedElement = RemoteElement(
      publicId: 'el-2',
      strategyPublicId: 'strat-1',
      pagePublicId: 'page-1',
      elementType: 'text',
      payload: '{}',
      sortIndex: 0,
      revision: 2,
      deleted: true,
    );
    const lineup = RemoteLineup(
      publicId: 'lineup-1',
      strategyPublicId: 'strat-1',
      pagePublicId: 'page-2',
      payload: '{}',
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
