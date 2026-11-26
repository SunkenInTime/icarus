import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

final class StrategyOpening {
  const StrategyOpening({
    required this.attempt,
    required this.strategyId,
    required this.source,
  });

  final int attempt;
  final String strategyId;
  final StrategySource source;
}

final class StrategyOpeningNotifier extends Notifier<StrategyOpening?> {
  var _attempt = 0;
  var _settled = 0;

  @override
  StrategyOpening? build() => null;

  int begin(String strategyId, {required StrategySource source}) {
    _counted(_attempt + 1);
    state = StrategyOpening(
      attempt: _attempt,
      strategyId: strategyId,
      source: source,
    );
    return _attempt;
  }

  int get opens => _attempt;

  bool isLatest(int attempt) => attempt == _attempt;

  void settle(int attempt) {
    if (attempt > _settled) _settled = attempt;
    if (_settled >= _attempt) state = null;
  }

  void endAll() {
    _counted(_attempt + 1);
    _settled = _attempt;
    state = null;
  }

  void _counted(int opens) {
    _attempt = opens;
    ref.read(openCountProvider.notifier).state = opens;
  }
}

final openCountProvider = StateProvider<int>((ref) => 0);

final strategyOpeningProvider =
    NotifierProvider<StrategyOpeningNotifier, StrategyOpening?>(
  StrategyOpeningNotifier.new,
);
