import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';

final abilityBarProvider =
    NotifierProvider<AbilityBarProvider, AgentData?>(AbilityBarProvider.new);

class AbilityBarProvider extends Notifier<AgentData?> {
  AgentData? _setAside;

  @override
  AgentData? build() {
    return null;
  }

  /// Shows [data]'s abilities, or closes the bar for good when it is null.
  void updateData(AgentData? data) {
    _setAside = null;
    state = data;
  }

  /// Hides the bar because the user did something else on the page, keeping
  /// its agent for [bringBack].
  void setAside() {
    final shown = state;
    if (shown == null) return;
    _setAside = shown;
    state = null;
  }

  /// Shows the agent [setAside] hid, once the user is back on the select tool.
  void bringBack() {
    final agent = _setAside;
    if (agent == null) return;
    _setAside = null;
    state = agent;
  }
}
