import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/hive_boxes.dart' as names;
import 'package:icarus/domain/folder.dart';
import 'package:icarus/strategy/strategy_models.dart';

const aliasForTheName = HiveBoxNames.strategiesBox;

void readsAroundTheView(StrategyData strategy, Folder folder, dynamic record) {
  Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategy.id);
  Hive.box<Folder>(HiveBoxNames.foldersBox).values.toList();
  Hive.isBoxOpen(HiveBoxNames.strategiesBox);
  strategy.box;
  folder.box;
  Hive.box<dynamic>('strategy_box').get(strategy.id);
  Hive.box<dynamic>(aliasForTheName).values;
  Hive.box<dynamic>(names.HiveBoxNames.foldersBox).values;
  final open = Hive.box<StrategyData>;
  open(HiveBoxNames.strategiesBox);
  record.box;
}

int countOf(Box<StrategyData> strategies) => strategies.length;

ValueListenable<Box<Folder>> watchFolders(Box<Folder> folders) =>
    folders.listenable();

void readsThroughNamesAndValuesTheTypesDoNotShow(dynamic heldBox) {
  Hive.box<dynamic>(aliasForTheName).length;
  Hive.box<dynamic>('strategy' '_box').length;
  Hive.box<dynamic>('folder' + '_box').length;
  Hive.box<dynamic>('STRATEGY_BOX').length;
  heldBox.get('some-id');
}
