import 'package:hive_ce/hive.dart';
import 'package:icarus/hive/hive_adapters.dart';
import 'package:icarus/hive/hive_registrar.g.dart';

const int _folderAdapterTypeId = 17;

void registerIcarusAdapters(HiveInterface hive) {
  hive.registerAdapters();
  if (!hive.isAdapterRegistered(_folderAdapterTypeId)) {
    hive.registerAdapter(FolderAdapter());
  }
}

void registerIcarusIsolatedAdapters(IsolatedHiveInterface hive) {
  hive.registerAdapters();
  if (!hive.isAdapterRegistered(_folderAdapterTypeId)) {
    hive.registerAdapter(FolderAdapter());
  }
}
