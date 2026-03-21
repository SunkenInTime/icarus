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
}
