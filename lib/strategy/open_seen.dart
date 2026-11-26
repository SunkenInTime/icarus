final class OpenSeen {
  const OpenSeen(this.strategyId, this.opens);

  final String? strategyId;
  final int opens;

  bool isNow(OpenSeen now) =>
      opens == now.opens && strategyId == now.strategyId;
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

sealed class OpenChange {
  const OpenChange();
}

final class Changed extends OpenChange {
  const Changed(this.after);

  final OpenSeen after;
}

final class GaveWay extends OpenChange {
  const GaveWay();
}
