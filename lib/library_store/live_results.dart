import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus_library/icarus_library.dart' show Account;

abstract interface class LiveResults {
  void liveOpened(String strategyId, ReadOf subject);

  void liveArrived(
    String strategyId,
    ReadOf subject,
    Account account,
    StoreReadOutcome outcome,
  );

  void liveClosed(String strategyId, ReadOf subject);
}

final class NoLiveResults implements LiveResults {
  const NoLiveResults();

  @override
  void liveOpened(String strategyId, ReadOf subject) {}

  @override
  void liveArrived(
    String strategyId,
    ReadOf subject,
    Account account,
    StoreReadOutcome outcome,
  ) {}

  @override
  void liveClosed(String strategyId, ReadOf subject) {}
}
