import 'dart:io';

import 'package:hive_ce/hive_ce.dart';

import '../store/engine.dart';

Future<Stored<T>> guarded<T>(Future<T> Function() task) async {
  try {
    return Done(await task());
  } on FileSystemException catch (error) {
    return StorageFailed(DeviceFailure(error.toString()));
  } on HiveError catch (error) {
    return StorageFailed(DeviceFailure(error.message));
  }
}
