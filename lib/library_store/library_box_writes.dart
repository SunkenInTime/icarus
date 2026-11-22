import 'dart:async';

import 'package:icarus/library_store/hive_reads.dart';

final class LibraryBoxWrites {
  LibraryBoxWrites() {
    _subscriptions = [
      for (final events in libraryBoxEvents()) events.listen((_) => _count++),
    ];
  }

  late final List<StreamSubscription<Object?>> _subscriptions;
  var _count = 0;

  int get count => _count;

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}
