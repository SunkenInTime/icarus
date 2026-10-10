import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';

Map<String, dynamic> _element(String kind, Map<String, dynamic> data,
        {int payloadVersion = 1}) =>
    {'kind': kind, 'payloadVersion': payloadVersion, 'data': data};

Map<String, dynamic> _agent([Map<String, dynamic> overrides = const {}]) =>
    _element('agent', {
      'id': 'agent-1',
      'elementType': 'agent',
      'kind': 'viewCone',
      'type': 'sova',
      'position': {'dx': 10.0, 'dy': 20.0},
      'isAlly': true,
      'rotation': 0.0,
      'length': 1.0,
      ...overrides,
    });

Map<String, dynamic> _group({
  List<Map<String, dynamic>>? links,
  List<Map<String, dynamic>>? landings,
}) =>
    {
      'kind': 'lineups',
      'payloadVersion': 1,
      'data': {
        'id': 'g',
        'origins': [
          {
            'id': 'o1',
            'agent': {'id': 'a1'},
          },
        ],
        'landings': landings ??
            [
              {
                'id': 'l1',
                'ability': {'id': 'b1'},
              },
            ],
        'links': links ??
            [
              {'id': 'k1', 'originId': 'o1', 'landingId': 'l1', 'notes': ''},
            ],
      },
    };

void main() {
  group('elementMergeFields', () {
    test('names the fields that changed', () {
      expect(
        elementMergeFields(_agent(), _agent({'isAlly': false})),
        ['isAlly'],
      );
    });

    test('names every field that moves with one that changed', () {
      // A view cone's handle sets rotation and length together.
      expect(
        elementMergeFields(_agent(), _agent({'rotation': 90.0})),
        ['length', 'rotation'],
      );
    });

    test('names a field the edit removed', () {
      expect(
        elementMergeFields(
          _agent({'visionElevation': 2.0}),
          _agent(),
        ),
        ['visionElevation'],
      );
    });

    test('is empty when nothing in the payload changed', () {
      expect(elementMergeFields(_agent(), _agent()), isEmpty);
    });

    test('cannot merge a change of what the element is', () {
      expect(
        elementMergeFields(_agent(), _agent({'kind': 'circle'})),
        isNull,
      );
      expect(elementMergeFields(_agent(), _agent({'type': 'jett'})), isNull);
    });

    test('cannot merge across payload versions', () {
      expect(
        elementMergeFields(
          _agent(),
          _element('agent', _agent()['data'] as Map<String, dynamic>,
              payloadVersion: 2),
        ),
        isNull,
      );
    });

    test('compares as the normalizer leaves both payloads', () {
      Object? withWeapon(Object? payload) {
        final data = Map<String, dynamic>.from(
            (payload as Map)['data'] as Map<String, dynamic>)
          ..putIfAbsent('weapon', () => 'none');
        return {...payload, 'data': data};
      }

      expect(
        elementMergeFields(_agent(), _agent({'weapon': 'none'}),
            normalize: withWeapon),
        isEmpty,
      );
    });

    test('groups a drawing\'s geometry with its bounding box', () {
      final before = _element('drawing', {
        'id': 'd',
        'elementType': 'drawing',
        'type': 'lineDrawing',
        'lineStart': {'dx': 0.0, 'dy': 0.0},
        'lineEnd': {'dx': 1.0, 'dy': 1.0},
        'boundingBox': {'min': {}, 'max': {}},
        'colorValue': 1,
      });
      final after = {
        ...before,
        'data': {
          ...before['data'] as Map<String, dynamic>,
          'lineEnd': {'dx': 5.0, 'dy': 5.0},
        },
      };
      expect(elementMergeFields(before, after),
          ['boundingBox', 'lineEnd', 'lineStart']);
    });
  });

  group('lineupMergeFields', () {
    test('names each item added, removed or changed', () {
      final after = _group(
        links: [
          {'id': 'k1', 'originId': 'o1', 'landingId': 'l1', 'notes': 'mine'},
          {'id': 'k2', 'originId': 'o1', 'landingId': 'l2', 'notes': ''},
        ],
        landings: [
          {
            'id': 'l1',
            'ability': {'id': 'b1'},
          },
          {
            'id': 'l2',
            'ability': {'id': 'b2'},
          },
        ],
      );
      expect(lineupMergeFields(_group(), after),
          ['landings/l2', 'links/k1', 'links/k2']);
    });

    test('cannot merge another group', () {
      final other = _group();
      (other['data'] as Map)['id'] = 'h';
      expect(lineupMergeFields(_group(), other), isNull);
    });
  });

  group('mergeFieldValue and the base', () {
    test('reads an element field, and knows an absent one', () {
      expect(mergeFieldValue(_agent(), 'isAlly', lineup: false),
          (present: true, value: true));
      expect(mergeFieldValue(_agent(), 'lineUpID', lineup: false).present,
          isFalse);
    });

    test('reads a lineup item', () {
      final link = mergeFieldValue(_group(), 'links/k1', lineup: true);
      expect(link.present, isTrue);
      expect((link.value as Map)['notes'], '');
      expect(
          mergeFieldValue(_group(), 'links/k9', lineup: true).present, isFalse);
    });

    test('records present fields only', () {
      expect(
        mergeBaseValues(_agent(), ['isAlly', 'lineUpID'], lineup: false),
        {'isAlly': true},
      );
    });
  });

  group('FieldMerge', () {
    const merge = FieldMerge(
      fields: ['isAlly', 'lineUpID'],
      base: {'isAlly': true},
    );

    test('round-trips through JSON, absent base values included', () {
      final json = merge.toJson();
      expect(json['base'], [
        {'field': 'isAlly', 'value': true},
        {'field': 'lineUpID'},
      ]);
      expect(FieldMerge.fromJson(json), merge);
    });

    test('without its base sends none', () {
      expect(merge.withoutBase().toJson().containsKey('base'), isFalse);
    });

    test('takes new base values for the fields given', () {
      final moved = merge.withBaseValues({
        'isAlly': (present: true, value: false),
        'lineUpID': (present: true, value: 'spot'),
      });
      expect(moved.base, {'isAlly': false, 'lineUpID': 'spot'});
    });
  });

  group('forSend', () {
    final patch = ElementPatchOp(
      opId: 'op',
      elementPublicId: 'agent-1',
      pagePublicId: 'page',
      payload: _agent({'isAlly': false}),
      sortIndex: 3,
      expectedElementRevision: 2,
      merge: const FieldMerge(fields: ['isAlly'], base: {'isAlly': true}),
    );
    const delete = ElementDeleteOp(
      opId: 'op',
      elementPublicId: 'agent-1',
      pagePublicId: 'page',
      expectedElementRevision: 2,
    );

    test('live work wins as the last write', () {
      expect(patch.forSend(live: true).merge?.base, isNull);
      expect(
        (delete.forSend(live: true) as ElementDeleteOp).lastWriterWins,
        isTrue,
      );
    });

    test('other work carries its base and a checked delete', () {
      expect(patch.forSend(live: false).merge?.base, {'isAlly': true});
      expect(
        (delete.forSend(live: false) as ElementDeleteOp).lastWriterWins,
        isFalse,
      );
    });

    test('a merge survives the durable round trip and a new op id', () {
      final restored = StrategyOp.fromJson(patch.toConvexJson());
      expect(restored.merge, patch.merge);
      expect(restored.withOpId('other').merge, patch.merge);
      expect((restored as ElementPatchOp).sortIndex, 3);
    });

    test('an op written before field merging reads with no merge', () {
      final legacy = Map<String, dynamic>.from(patch.toConvexJson())
        ..remove('merge');
      expect(StrategyOp.fromJson(legacy).merge, isNull);
    });
  });

  group('review round 1', () {
    test('a field one side lacks and the other holds as null is unchanged', () {
      final before = _agent();
      final after = _agent({'visionElevation': null});
      expect(elementMergeFields(before, after), isEmpty);
    });

    test("a utility's groups follow its type", () {
      Map<String, dynamic> utility(String type,
              [Map<String, dynamic> more = const {}]) =>
          _element('utility', {
            'id': 'u',
            'elementType': 'utility',
            'type': type,
            'position': {'dx': 0.0, 'dy': 0.0},
            'rotation': 0.0,
            'length': 1.0,
            'customWidth': 2.0,
            'customLength': 3.0,
            ...more,
          });
      // Moving a view cone leaves its rotation to whoever turns it.
      expect(
        elementMergeFields(
            utility('viewCone90'),
            utility('viewCone90', {
              'position': {'dx': 5.0, 'dy': 5.0}
            })),
        ['position'],
      );
      // A custom rectangle's resize moves it about its rotation.
      expect(
        elementMergeFields(utility('customRectangle'),
            utility('customRectangle', {'customWidth': 4.0})),
        ['customLength', 'customWidth', 'position', 'rotation'],
      );
    });

    test('an outbox record of merged work is one older builds skip', () {
      DurableOutboxRecord record(StrategyOp op) => DurableOutboxRecord(
            accountId: 'a',
            strategyPublicId: 's',
            entityKey: EntitySyncKey.forStrategyOp(op)!,
            pending: PendingOp(op: op, clientId: 'c'),
            status: DurableOutboxStatus.queued,
            createdAt: DateTime(2026),
            updatedAt: DateTime(2026),
            latestServerPayload: const {'kind': 'agent'},
          );
      final merged = ElementPatchOp(
        opId: 'op',
        elementPublicId: 'agent-1',
        pagePublicId: 'page',
        payload: _agent(),
        sortIndex: 0,
        expectedElementRevision: 1,
        merge: const FieldMerge(fields: ['isAlly'], base: {'isAlly': true}),
      );
      final whole = ElementPatchOp(
        opId: 'op',
        elementPublicId: 'agent-1',
        pagePublicId: 'page',
        payload: _agent(),
        sortIndex: 0,
        expectedElementRevision: 1,
      );
      expect(record(merged).toJson()['outboxVersion'],
          fieldMergeOutboxRecordVersion);
      expect(
          record(whole).toJson()['outboxVersion'], durableOutboxRecordVersion);
      final restored = DurableOutboxRecord.fromJson(record(merged).toJson());
      expect(restored.pending.op.merge, merged.merge);
      expect(restored.latestServerPayload, {'kind': 'agent'});
    });
  });
}
