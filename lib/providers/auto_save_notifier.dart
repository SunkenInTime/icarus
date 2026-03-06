import 'package:flutter_riverpod/flutter_riverpod.dart';

final autoSaveProvider =
    NotifierProvider<AutoSaveNotifier, int>(AutoSaveNotifier.new);

class AutoSaveNotifier extends Notifier<int> {
  @override
  int build() {
    return 0;
  }

  void ping() {
    state = state + 1;
  }
}

