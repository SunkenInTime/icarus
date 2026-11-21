import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/domain/folder.dart';
import 'package:icarus/strategy/strategy_models.dart';

Future<void> writesAroundTheFunnel(StrategyData strategy, Folder folder) async {
  final strategies = Hive.box<StrategyData>(HiveBoxNames.strategiesBox);
  final folders = Hive.box<Folder>(HiveBoxNames.foldersBox);
  await strategies.put(strategy.id, strategy);
  await strategies.putAll({strategy.id: strategy});
  await strategies.delete(strategy.id);
  await strategies.deleteAll([strategy.id]);
  await strategies.clear();
  await folders.put(folder.id, folder);
  await folders.delete(folder.id);
  await strategy.save();
  await folder.delete();
  final save = folder.save;
  await save();
  strategies.get(strategy.id);
  folders.values.toList().add(folder);
}
