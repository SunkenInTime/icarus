import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/page_copy_id.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/page_transition/transition_planner.dart';

const _occurrence = '0f8fad5b-d9cb-469f-a165-70867728950e';

PlacedAgent _agent(String id, Offset position) =>
    PlacedAgent(id: id, type: AgentType.jett, position: position);

Map<String, PlacedWidget> _page(List<PlacedWidget> widgets) =>
    {for (final widget in widgets) widget.id: widget};

void main() {
  group('pageCopyRoot', () {
    test('an id that is no copy is its own root', () {
      expect(pageCopyRoot('agent-1'), 'agent-1');
      expect(pageCopyRoot('replay-player-3'), 'replay-player-3');
    });

    test('a copy names the item it was copied from', () {
      expect(pageCopyRoot('agent-1~cp1~$_occurrence'), 'agent-1');
      expect(
        pageCopyRoot('replay-player-3~cp1~$_occurrence'),
        'replay-player-3',
      );
    });

    test('only the mark with a canonical uuid after it makes a copy', () {
      expect(pageCopyRoot('a~cp1~not-a-uuid'), 'a~cp1~not-a-uuid');
      expect(pageCopyRoot('a~cp1~${_occurrence.toUpperCase()}'),
          'a~cp1~${_occurrence.toUpperCase()}');
      expect(pageCopyRoot('~cp1~$_occurrence'), '~cp1~$_occurrence');
      expect(pageCopyRoot('a~cp2~$_occurrence'), 'a~cp2~$_occurrence');
    });
  });

  group('newPageCopyId', () {
    test('a copy of a copy keeps the first root, so ids never nest', () {
      final first = newPageCopyId('agent-1');
      final second = newPageCopyId(first);
      expect(pageCopyRoot(first), 'agent-1');
      expect(pageCopyRoot(second), 'agent-1');
      expect(second, isNot(first));
      expect('~cp1~'.allMatches(second), hasLength(1));
    });
  });

  group('TransitionPlanner.diff pairs copies by the item they came from', () {
    test('a copy glides from its original', () {
      final original = _agent('agent-1', const Offset(10, 10));
      final copy = _agent('agent-1~cp1~$_occurrence', const Offset(90, 90));

      final entries = TransitionPlanner.diff(
        _page([original]),
        _page([copy]),
      );

      final move = entries.single;
      expect(move.kind, TransitionKind.move);
      expect(move.from, original);
      expect(move.to, copy);
    });

    test('the same id still pairs first', () {
      final original = _agent('agent-1', const Offset(10, 10));
      final moved = _agent('agent-1', const Offset(50, 50));
      final copy = _agent('agent-1~cp1~$_occurrence', const Offset(90, 90));

      final entries = TransitionPlanner.diff(
        _page([original]),
        _page([moved, copy]),
      );

      expect(
        entries.map((e) => (e.kind, e.id)),
        unorderedEquals([
          (TransitionKind.move, 'agent-1'),
          (TransitionKind.appear, copy.id),
        ]),
      );
    });

    test('a root on a page twice pairs nothing: that would be a guess', () {
      final original = _agent('agent-1', const Offset(10, 10));
      final copyA = _agent('agent-1~cp1~$_occurrence', const Offset(50, 50));
      final copyB = _agent(
        'agent-1~cp1~1b4e28ba-2fa1-41d2-883f-0016d3cca427',
        const Offset(90, 90),
      );

      final entries = TransitionPlanner.diff(
        _page([original]),
        _page([copyA, copyB]),
      );

      expect(
        entries.map((e) => e.kind),
        unorderedEquals([
          TransitionKind.appear,
          TransitionKind.appear,
          TransitionKind.disappear,
        ]),
      );
    });

    test('items of different kinds never pair', () {
      final agent = _agent('item', const Offset(10, 10));
      final text = PlacedText(
        id: 'item~cp1~$_occurrence',
        position: const Offset(90, 90),
      );

      final entries = TransitionPlanner.diff(_page([agent]), _page([text]));

      expect(
        entries.map((e) => e.kind),
        unorderedEquals([TransitionKind.appear, TransitionKind.disappear]),
      );
    });

    test('two copies of one item glide between themselves', () {
      final onPage2 = _agent('agent-1~cp1~$_occurrence', const Offset(10, 10));
      final onPage3 = _agent(
        'agent-1~cp1~1b4e28ba-2fa1-41d2-883f-0016d3cca427',
        const Offset(90, 90),
      );

      final move = TransitionPlanner.diff(
        _page([onPage2]),
        _page([onPage3]),
      ).single;

      expect(move.kind, TransitionKind.move);
      expect(move.from, onPage2);
      expect(move.to, onPage3);
    });
  });

  group('drawings between pages', () {
    Line stroke(String id, {Offset end = const Offset(100, 100)}) => Line(
          id: id,
          lineStart: const Offset(10, 10),
          lineEnd: end,
          colorValue: 0xFFFFFFFF,
          isDotted: false,
          hasArrow: false,
        );

    test('a copied stroke counts as its original', () {
      expect(
        TransitionPlanner.drawingsChanged(
          [stroke('stroke-1')],
          [stroke('stroke-1~cp1~$_occurrence')],
        ),
        isFalse,
      );
    });

    test('a copied stroke that moved, or another stroke, is a change', () {
      expect(
        TransitionPlanner.drawingsChanged(
          [stroke('stroke-1')],
          [stroke('stroke-1~cp1~$_occurrence', end: const Offset(200, 50))],
        ),
        isTrue,
      );
      expect(
        TransitionPlanner.drawingsChanged(
          [stroke('stroke-1')],
          [stroke('stroke-2')],
        ),
        isTrue,
      );
    });
  });
}
