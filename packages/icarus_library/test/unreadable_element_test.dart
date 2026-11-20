import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

bool _anyPayload(ElementPayload payload) => true;

void main() {
  final fromNewerBuild = <String, Object?>{
    'publicId': 'smoke',
    'pagePublicId': 'page-a',
    'payload': {
      'kind': 'hologram',
      'payloadVersion': 1,
      'data': {
        'id': 'smoke',
        'position': {'x': 3, 'y': 4},
        'flicker': [1, 2, 3],
      },
    },
    'sortIndex': 5,
    'revision': 7,
    'deleted': false,
  };

  final rowsThisBuildCannotRead = {
    'a kind from a newer build': fromNewerBuild,
    'a payload version from a newer build': {
      ...fromNewerBuild,
      'payload': {
        'kind': 'ability',
        'payloadVersion': 9,
        'data': {'id': 'smoke', 'shape': 'new'},
      },
    },
    'data that is not an object': {
      ...fromNewerBuild,
      'payload': {'kind': 'agent', 'payloadVersion': 1, 'data': 'garbled'},
    },
    'no payload envelope at all': {...fromNewerBuild, 'payload': 'garbled'},
  };

  for (final MapEntry(key: what, value: json)
      in rowsThisBuildCannotRead.entries) {
    group('An element with $what', () {
      late ElementRow row;
      late Session session;

      setUp(() {
        row = readValue(
          ElementRow.decode(jsonDecode(jsonEncode(json)), canRead: _anyPayload),
        );
        session = Session(
          strategyRows(
            elements: [
              row,
              element('jett', pageId: 'page-a'),
            ],
          ),
        );
      });

      test('is read as unreadable and saved back exactly as it came', () {
        expect(row, isA<UnreadableElement>());
        expect(jsonEncode(row.toJson()), jsonEncode(json));
      });

      test('survives every op aimed at the rest of the strategy', () {
        final ops = <StrategyOp>[
          const ElementDeleteOp(
            opId: 'delete-jett',
            elementPublicId: 'jett',
            pagePublicId: 'page-a',
            expectedElementRevision: 1,
          ),
          const PageAddOp(
            opId: 'copy-page',
            pagePublicId: 'page-copy',
            sortIndex: 0,
            expectedStrategyRevision: 1,
            copyContentFromPagePublicId: 'page-a',
          ),
          const PageReorderOp(
            opId: 'move-page',
            pagePublicId: 'page-a',
            sortIndex: 2,
            expectedStrategyRevision: 2,
          ),
          const PageDeleteOp(
            opId: 'delete-page',
            pagePublicId: 'page-a',
            expectedStrategyRevision: 3,
          ),
        ];
        for (final op in ops) {
          session.apply(op);
          expect(session.rows.element('smoke'), row, reason: op.opId);
        }
        expect(
          jsonEncode(session.rows.element('smoke')!.toJson()),
          jsonEncode(json),
        );
      });

      test('is never the target of an edit, move, delete or re-add', () {
        final aimedAtIt = <StrategyOp>[
          ElementPatchOp(
            opId: 'patch',
            elementPublicId: 'smoke',
            expectedElementRevision: 7,
            payload: agentPayload('smoke', {}),
          ),
          const ElementReorderOp(
            opId: 'reorder',
            elementPublicId: 'smoke',
            pagePublicId: 'page-a',
            sortIndex: 0,
            expectedElementRevision: 7,
          ),
          const ElementDeleteOp(
            opId: 'delete',
            elementPublicId: 'smoke',
            pagePublicId: 'page-a',
            expectedElementRevision: 7,
            lastWriterWins: true,
          ),
          ElementAddOp(
            opId: 'add',
            elementPublicId: 'smoke',
            pagePublicId: 'page-a',
            payload: agentPayload('smoke', {}),
            sortIndex: 0,
            expectedElementRevision: 7,
          ),
        ];
        for (final op in aimedAtIt) {
          expect(
            refused(session.attempt(op)),
            const UnreadableTarget('smoke'),
            reason: op.opId,
          );
        }
      });
    });
  }

  test('a copied page carries a copy of an element this build cannot read', () {
    final row = readValue(
      ElementRow.decode(fromNewerBuild, canRead: _anyPayload),
    );
    final session = Session(strategyRows(elements: [row]));
    session.apply(
      const PageAddOp(
        opId: 'copy-page',
        pagePublicId: 'page-copy',
        sortIndex: 0,
        expectedStrategyRevision: 1,
        copyContentFromPagePublicId: 'page-a',
      ),
    );
    final copy = session.rows.elementsOn('page-copy').single;
    expect(copy, isA<UnreadableElement>());
    final payload = copy.toJson()['payload']! as Map<String, Object?>;
    expect(payload['kind'], 'hologram');
    expect((payload['data']! as Map<String, Object?>)['flicker'], [1, 2, 3]);
    expect(session.rows.element('smoke'), row);
  });

  test('an op from a newer build makes a row this build leaves alone', () {
    final session = Session(strategyRows());
    session.apply(
      ElementAddOp(
        opId: 'from-newer-outbox',
        elementPublicId: 'wall',
        pagePublicId: 'page-a',
        payload: ElementPayload(
          kind: ElementKind.ability,
          payloadVersion: newestElementPayloadVersion + 1,
          data: {'id': 'wall'},
        ),
        sortIndex: 0,
      ),
    );
    expect(session.rows.element('wall'), isA<UnreadableElement>());
  });

  test(
    'an element the editor cannot draw is carried like one from a newer build',
    () {
      final json = <String, Object?>{
        'publicId': 'jett',
        'pagePublicId': 'page-a',
        'payload': {
          'kind': 'agent',
          'payloadVersion': 1,
          'data': {'id': 'jett'},
        },
        'sortIndex': 0,
        'revision': 1,
        'deleted': false,
      };
      final row = readValue(
        ElementRow.decode(
          json,
          canRead: (payload) => payload.data.containsKey('position'),
        ),
      );
      expect(row, isA<UnreadableElement>());
      expect(jsonEncode(row.toJson()), jsonEncode(json));
      expect(
        refused(
          applyOp(
            strategyRows(elements: [row]),
            const ElementDeleteOp(
              opId: 'delete',
              elementPublicId: 'jett',
              pagePublicId: 'page-a',
              expectedElementRevision: 1,
            ),
          ),
        ),
        const UnreadableTarget('jett'),
      );
    },
  );
}
