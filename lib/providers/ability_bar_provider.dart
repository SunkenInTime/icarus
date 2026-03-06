import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/agents.dart';

final abilityBarProvider =
    NotifierProvider<AbilityBarProvider, AgentData?>(AbilityBarProvider.new);

class AbilityBarProvider extends Notifier<AgentData?> {
  @override
  AgentData? build() {
    return null;
  }

  void updateData(AgentData? data) {
    state = data;
  }
}

