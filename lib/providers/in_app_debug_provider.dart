import 'package:flutter_riverpod/flutter_riverpod.dart';

final inAppDebugProvider =
    NotifierProvider<InAppDebugProvider, List<String>>(InAppDebugProvider.new);

class InAppDebugProvider extends Notifier<List<String>> {
  @override
  List<String> build() {
    return [];
  }

  void addLog(String log) {
    state = [...state, log];
  }

  void bulkAddLogs(List<String> logs) {
    state = [...state, ...logs];
  }

  void clearLogs() {
    state = [];
  }
}
