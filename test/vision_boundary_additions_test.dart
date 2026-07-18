import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_vision_boundary.dart';

void main() {
  const source = '''
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <path fill="#271406" d="M0 0H100V100H0Z"/>
</svg>
''';

  test('shared audit boundaries mirror for defense and keep layer scope', () {
    final additions = VisionBoundaryAdditions.fromJson({
      'version': 1,
      'maps': {
        'ascent': {
          'shared': [
            {
              'id': 'a-main-box',
              'label': 'A Main box',
              'closed': true,
              'points': [
                [0.1, 0.2],
                [0.2, 0.2],
                [0.2, 0.3],
              ],
              'activeElevations': [300, 800],
            },
          ],
        },
      },
    });

    final attack = additions.entriesFor(MapValue.ascent, isAttack: true).single;
    final defense = additions
        .entriesFor(MapValue.ascent, isAttack: false)
        .single;

    expect(attack.id, 'audit_a-main-box');
    expect(attack.points.first.dx, closeTo(0.1, 0.0001));
    expect(defense.points.first.dx, closeTo(0.9, 0.0001));
    expect(defense.points.first.dy, closeTo(0.8, 0.0001));
    expect(
      additions
          .overridesFor(MapValue.ascent, isAttack: true)
          .values
          .single
          .activeElevations,
      [300, 800],
    );
  });

  test(
    'SVG parser includes hand-audited geometry with an explicit stable id',
    () {
      final additions = VisionBoundaryAdditions.fromJson({
        'version': 1,
        'maps': {
          'ascent': {
            'attack': [
              {
                'id': 'mid-wall',
                'label': 'Mid wall',
                'closed': false,
                'points': [
                  [0.25, 0.5],
                  [0.75, 0.5],
                ],
              },
            ],
          },
        },
      });

      final boundary = SvgVisionBoundary.parse(
        map: MapValue.ascent,
        source: source,
        additions: additions,
        isAttack: true,
      );
      final audited = boundary.collisionGroups.singleWhere(
        (group) => group.id == 'audit_mid-wall',
      );

      expect(audited.isClosed, isFalse);
      expect(audited.requiresEvidence, isFalse);
      expect(audited.segments, hasLength(1));
    },
  );

  test('rejects duplicate side ids and out-of-range normalized points', () {
    expect(
      () => VisionBoundaryAdditions.fromJson({
        'version': 1,
        'maps': {
          'ascent': {
            'shared': [
              {
                'id': 'same-wall',
                'label': 'Shared wall',
                'closed': false,
                'points': [
                  [0.1, 0.1],
                  [0.2, 0.2],
                ],
              },
            ],
            'attack': [
              {
                'id': 'same-wall',
                'label': 'Duplicate wall',
                'closed': false,
                'points': [
                  [0.2, 0.2],
                  [0.3, 0.3],
                ],
              },
            ],
          },
        },
      }),
      throwsFormatException,
    );
    expect(
      () => VisionBoundaryAdditions.fromJson({
        'version': 1,
        'maps': {
          'ascent': {
            'attack': [
              {
                'id': 'bad-wall',
                'label': 'Bad wall',
                'closed': false,
                'points': [
                  [-0.1, 0.2],
                  [0.3, 0.4],
                ],
              },
            ],
          },
        },
      }),
      throwsFormatException,
    );
  });
}
