import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/codec.dart';
import 'package:test/test.dart';

import 'cloud_support.dart';
import 'support.dart';

const olderLife = 1767000000000;
const newerLife = 1768000000000;

LiveElement bornAt(String id, int revision, int life) => LiveElement(
  publicId: id,
  pagePublicId: 'page-a',
  payload: agentPayload(id, const {}),
  sortIndex: 0,
  revision: revision,
  unknownFields: jsonObject({'createdAt': life}),
);

LiveElement withoutLife(String id, int revision) => LiveElement(
  publicId: id,
  pagePublicId: 'page-a',
  payload: agentPayload(id, const {}),
  sortIndex: 0,
  revision: revision,
);

PageRead pageAWith(List<ElementRow> elements) => PageRead(
  page: initialRows().page('page-a')!,
  elements: elements,
  lineupGroups: const [],
);

Shown shownAfter(List<List<ElementRow>> reads) {
  var shown = Shown.nothing
      .taken(headerReadOf(initialRows()), arrival: null)
      .shown;
  for (final elements in reads) {
    shown = shown.taken(pageAWith(elements), arrival: null).shown;
  }
  return shown;
}

Map<String, Object?> roundTripped(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  group('a version orders by life before revision', () {
    test('a higher revision under an older life never outranks a lower one '
        'under a newer life', () {
      const older = Version(9, life: olderLife);
      const newer = Version(1, life: newerLife);
      expect(older > newer, isFalse);
      expect(newer > older, isTrue);
      expect(older < newer, isTrue);
    });

    test('within one life, and where either life is unknown, the revision '
        'decides as before', () {
      expect(
        const Version(3, life: olderLife) > const Version(2, life: olderLife),
        isTrue,
      );
      expect(const Version(9) > const Version(1, life: newerLife), isTrue);
      expect(const Version(1, life: newerLife) > const Version(9), isFalse);
    });

    test('a page result of a row\'s older life does not replace what a result '
        'of its newer life showed, whatever its revision', () {
      final shown = shownAfter([
        [bornAt('e1', 1, newerLife)],
        [bornAt('e1', 9, olderLife)],
      ]);
      expect(
        shown.highest[const ElementTarget('e1')],
        const Version(1, life: newerLife),
      );
    });

    test('a result of the row\'s newer life replaces one of its older life at '
        'a higher revision', () {
      final shown = shownAfter([
        [bornAt('e1', 9, olderLife)],
        [bornAt('e1', 1, newerLife)],
      ]);
      expect(
        shown.highest[const ElementTarget('e1')],
        const Version(1, life: newerLife),
      );
    });
  });

  group('a record written without a life', () {
    test('a queue entry reads back with no life and writes back unchanged', () {
      final written = {
        'version': 1,
        'kind': 'op',
        'op': movePatch('move', elementId: 'e1').toJson(),
        'scope': {'page': 'page-a'},
        'authored': {
          'revision': 1,
          'digest': 'abc',
          'produces': {'page': 'page-a', 'revision': 2, 'digest': 'def'},
        },
        'authoredIn': 1,
        'authoredAt': 0,
        'retriedAfter': 0,
        'work': 'op',
        'refusal': {
          'rejected': 'revision_mismatch',
          'current': {
            'target': 'element',
            'revision': 3,
            'value': <String, Object?>{},
          },
        },
      };
      final entry = switch (decodeEntry(1, written, sendable: true)) {
        Read(value: final PendingOp entry) => entry,
        final other => fail('expected an entry, got $other'),
      };
      final authored = entry.authored as AuthoredRow;
      expect(authored.life, isNull);
      expect(authored.produces?.life, isNull);
      expect(
        (((entry.refusal as RefusedWith).refusal as RejectedByServer).current
                as ServerSnapshot)
            .life,
        isNull,
      );
      expect(roundTripped(entryToJson(entry)), roundTripped(written));
    });

    test('landed work reads back with no life and writes back unchanged', () {
      final written = {
        'version': 1,
        'op': movePatch('move', elementId: 'e1').toJson(),
        'revision': 2,
        'shape': 'whole',
        'own': true,
        'firstSentAt': 0,
      };
      final work = switch (landedFromText(1, 0, jsonEncode(written))) {
        CloudRowRead(:final value) => value,
        final other => fail('expected landed work, got $other'),
      };
      expect(work.life, isNull);
      expect(roundTripped(landedToJson(work)), roundTripped(written));
    });

    test('stored results with no lives read back with none, and a page '
        'whose rows have no lives writes no lives key', () {
      final shown = shownAfter([
        [withoutLife('e1', 3)],
      ]);
      final groups = shownToGroups(shown);
      expect(groups['page-a']!.keys, isNot(contains('lives')));
      final asMainWroteThem = {
        for (final MapEntry(:key, :value) in groups.entries)
          key: jsonEncode({...value}..remove('lives')),
      };
      final read = switch (shownFromGroups(asMainWroteThem)) {
        ShownRead(:final shown) => shown,
        final other => fail('expected results, got $other'),
      };
      expect(read.strategy?.life, isNull);
      expect(read.highest[const StrategyTarget()], const Version(1));
      expect(read.rows[const ElementTarget('e1')]?.life, isNull);
      expect(read.highest[const ElementTarget('e1')], const Version(3));
      expect(
        {
          for (final MapEntry(:key, :value) in shownToGroups(read).entries)
            key: roundTripped(value),
        },
        {
          for (final MapEntry(:key, :value) in asMainWroteThem.entries)
            key: jsonDecode(value),
        },
      );
    });

    test('a stored row without a life is ordered by revision against one with '
        'a life, as before', () {
      final shown = shownAfter([
        [withoutLife('e1', 3)],
        [bornAt('e1', 2, newerLife)],
      ]);
      expect(shown.highest[const ElementTarget('e1')], const Version(3));
    });

    test('lives that are known survive a write and a read', () {
      final shown = shownAfter([
        [bornAt('e1', 2, newerLife)],
      ]);
      final read = switch (shownFromGroups({
        for (final MapEntry(:key, :value) in shownToGroups(shown).entries)
          key: jsonEncode(value),
      })) {
        ShownRead(:final shown) => shown,
        final other => fail('expected results, got $other'),
      };
      expect(read.highest, shown.highest);
      expect(read.rows, shown.rows);
      expect(read.strategy, shown.strategy);
      expect(read.strategy?.life, isNotNull);
      expect(
        read.highest[const ElementTarget('e1')],
        const Version(2, life: newerLife),
      );
    });
  });
}
