import 'package:icarus_library/icarus_library.dart';

typedef Snapshot = ({
  Account? account,
  int? connection,
  int signIns,
  int signOuts,
});

sealed class ResultForStore {
  const ResultForStore(this.strategyId, this.stamp);

  final String strategyId;
  final Snapshot stamp;
}

final class ListResultForStore extends ResultForStore {
  const ListResultForStore(super.strategyId, super.stamp, this.header);

  final HeaderRead header;
}

final class PageResultForStore extends ResultForStore {
  const PageResultForStore(super.strategyId, super.stamp, this.page);

  final PageRead page;
}

sealed class ResultOutcome {
  const ResultOutcome();
}

final class ResultRecorded extends ResultOutcome {
  const ResultRecorded(this.session, {required this.added});

  final int session;
  final bool added;
}

final class ResultStale extends ResultOutcome {
  const ResultStale(this.why);

  final String why;
}

final class ResultNotRecorded extends ResultOutcome {
  const ResultNotRecorded(this.why);

  final String why;
}

abstract interface class ResultIntake {
  void resultsFrom(int signIns);

  Future<ResultOutcome> take(ResultForStore result);
}
