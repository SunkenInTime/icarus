import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/strategy/copied_page_check.dart';

import '../collab/strategy_copy_fixtures.dart';

bool drawable({
  List<Map<String, Object?>> elements = const [],
  List<Map<String, Object?>> lineups = const [],
}) =>
    copiedPageIsDrawable(pageSnapshotFromCopy(
      pageAnswer('a', elements: elements, lineups: lineups),
    ));

Map<String, Object?> _withPayload(
  Map<String, Object?> row,
  Map<String, Object?> Function(Map<String, Object?> payload) change,
) =>
    {...row, 'payload': change(Map.of(row['payload'] as Map<String, Object?>))};

void main() {
  test('a page whose every row hydrates is drawable', () {
    expect(
      drawable(
        elements: [agentRow('agent', 'a'), imageRow('image', 'a', 'pic')],
        lineups: [lineupRow('lineup', 'a', 'lineup-image')],
      ),
      isTrue,
    );
  });

  test('an agent that hydration cannot read makes the page not drawable', () {
    final agent = _withPayload(agentRow('agent', 'a'), (payload) {
      final data = Map.of(payload['data'] as Map<String, Object?>)
        ..remove('position');
      return {...payload, 'data': data};
    });
    expect(drawable(elements: [agentRow('fine', 'a'), agent]), isFalse);
  });

  test('a payload newer than this build reads makes the page not drawable', () {
    final agent = _withPayload(
      agentRow('agent', 'a'),
      (payload) => {...payload, 'payloadVersion': 99},
    );
    expect(drawable(elements: [agent]), isFalse);
  });

  test('a lineup group that cannot be read makes the page not drawable', () {
    final lineup = _withPayload(lineupRow('lineup', 'a', 'image'), (payload) {
      final data = Map.of(payload['data'] as Map<String, Object?>)
        ..remove('origins');
      return {...payload, 'data': data};
    });
    expect(drawable(lineups: [lineup]), isFalse);
  });

  test('a deleted row is not drawn, so it is not checked', () {
    final agent = _withPayload(
      agentRow('agent', 'a', deleted: true),
      (payload) => {...payload, 'data': <String, Object?>{}},
    );
    expect(drawable(elements: [agent]), isTrue);
  });
}
