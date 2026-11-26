import 'package:icarus/strategy/strategy_page_models.dart';

final class OpenSeen {
  const OpenSeen(this.strategyId, this.opens, {this.source, this.edits = 0});

  final String? strategyId;
  final StrategySource? source;
  final int opens;
  final int edits;

  bool isNow(OpenSeen now) => isTheSameOpen(now) && edits == now.edits;

  bool isTheSameOpen(OpenSeen now) =>
      opens == now.opens &&
      strategyId == now.strategyId &&
      source == now.source;

  OpenSeen withEdits(int edits) =>
      OpenSeen(strategyId, opens, source: source, edits: edits);
}

sealed class LeaveAnswer {
  const LeaveAnswer();
}

final class Leave extends LeaveAnswer {
  const Leave(this.seen);

  final OpenSeen seen;
}

final class Stay extends LeaveAnswer {
  const Stay();
}

sealed class LocalOpenChange {}

sealed class OpenChange implements LocalOpenChange {}

sealed class CloseChange {}

final class Changed implements OpenChange, CloseChange {
  const Changed(this.after);

  final OpenSeen after;
}

final class GaveWay implements OpenChange, CloseChange {
  const GaveWay();
}

final class Missing implements LocalOpenChange {
  const Missing();
}

sealed class EditorPush {
  const EditorPush();
}

final class Pushed extends EditorPush {
  const Pushed(this.closed);

  final Future<void> closed;
}

final class Refused extends EditorPush {
  const Refused();
}
