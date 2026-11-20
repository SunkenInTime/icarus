import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/page_transition/agent_path.dart';

void main() {
  group('AgentTransitionPath', () {
    test('samples by traveled distance instead of waypoint count', () {
      final path = AgentTransitionPath(const [
        Offset(0, 0),
        Offset(10, 0),
        Offset(10, 30),
      ]);

      expect(path.length, 40);
      expect(path.positionAt(0.5), const Offset(10, 10));
    });

    test('clamps progress to both ends', () {
      final path = AgentTransitionPath(const [Offset(2, 3), Offset(8, 9)]);

      expect(path.positionAt(-1), const Offset(2, 3));
      expect(path.positionAt(2), const Offset(8, 9));
    });

    test('a move with no route goes straight, never holding then jumping', () {
      final path =
          AgentTransitionPath.straight(const Offset(2, 3), const Offset(8, 9));
      expect(path.positionAt(0), const Offset(2, 3));
      expect(path.positionAt(.5), const Offset(5, 6));
      expect(path.positionAt(1), const Offset(8, 9));
    });
  });
}
