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

  void updateData(AgentData? data) {
    _setAside = null;
    state = data;
  }

  void setAside() {
    final shown = state;
    if (shown == null) return;
    _setAside = shown;
    state = null;
  }

  void bringBack() {
    final agent = _setAside;
    if (agent == null) return;
    _setAside = null;
    state = agent;
  }
}
