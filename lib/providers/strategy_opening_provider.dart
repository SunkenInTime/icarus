import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

final class StrategyOpeningNotifier extends Notifier<String?> {
  var _attempt = 0;
  var _settled = 0;
  StrategySource? _source;

  StrategySource? get source => state == null ? null : _source;

  @override
  String? build() => null;

  int begin(String strategyId, {required StrategySource source}) {
    _attempt += 1;
    _source = source;
    state = strategyId;
    return _attempt;
  }

  bool isLatest(int attempt) => attempt == _attempt;

  void settle(int attempt) {
    if (attempt > _settled) _settled = attempt;
    if (_settled >= _attempt) state = null;
  }

  void endAll() {
    _attempt += 1;
    _settled = _attempt;
    state = null;
  }
}

final strategyOpeningProvider =
    NotifierProvider<StrategyOpeningNotifier, String?>(
  StrategyOpeningNotifier.new,
);
