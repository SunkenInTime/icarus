import 'package:flutter_riverpod/flutter_riverpod.dart';

final teamProvider = NotifierProvider<TeamProvider, bool>(TeamProvider.new);

class TeamProvider extends Notifier<bool> {
  @override
  bool build() {
    return true;
  }

  void isAlly(bool value) {
    state = value;
  }
}

