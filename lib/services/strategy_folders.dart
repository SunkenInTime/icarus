import 'dart:io';

import 'package:icarus/config/drive_build.dart';
import 'package:path_provider/path_provider.dart';

String? _driveStore;

/// The folder that holds one folder per strategy, each with that strategy's
/// pictures. Every shipped build keeps them in the application support
/// directory, and users' pictures are there, so only a driver build run with
/// a store of its own may move them.
Future<Directory> strategyFoldersRoot() async {
  final store = _driveStore;
  return store != null ? Directory(store) : getApplicationSupportDirectory();
}

/// Keeps a driver run's strategy folders in the store it was given with
/// --hive-store-dir, so its pictures don't land among the real app's.
void keepStrategyFoldersInDriveStore(String hiveDirectoryPath) {
  if (driveBuild) _driveStore = hiveDirectoryPath;
}
