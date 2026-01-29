import 'package:flutter_riverpod/flutter_riverpod.dart';

final activePageProvider =
    NotifierProvider<ActivePageProvider, String?>(ActivePageProvider.new);

class ActivePageProvider extends Notifier<String?> {
  @override
  String? build() {
    return null;
  }

  void setActivePage(String pageID) {
    state = pageID;
  }
}
