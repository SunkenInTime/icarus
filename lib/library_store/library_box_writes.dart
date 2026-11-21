import 'dart:async';

import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/strategy/strategy_models.dart';

final class LibraryBoxWrites {
  LibraryBoxWrites() {
    _subscriptions = [
      for (final events in [
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox).watch(),
        Hive.box<Folder>(HiveBoxNames.foldersBox).watch(),
      ])
        events.listen((_) => _count++),
    ];
  }

  late final List<StreamSubscription<BoxEvent>> _subscriptions;
  var _count = 0;

  int get count => _count;

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}
