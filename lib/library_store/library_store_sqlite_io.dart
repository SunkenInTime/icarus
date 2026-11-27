import 'dart:io';

import 'package:icarus/config/drive_build.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/slowed_engine.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

Future<LibraryStoreOpened> openLibraryStore(
  File file, {
  String build = '',
  StorageEngine Function(StorageEngine engine)? wrapEngine,
}) async {
  try {
    await file.parent.create(recursive: true);
  } on FileSystemException catch (error) {
    return LibraryStoreRefused(file, DeviceFailure('$error'));
  }
  final engine = SqliteEngine(file.path);
  final StorageEngine slowed = driveBuild ? SlowedEngine(engine) : engine;
  final opened = wrapEngine?.call(slowed) ?? slowed;
  switch (await LibraryStore.open(opened, canRead: appCanRead, build: build)) {
    case StoreOpened(:final store, :final origin, :final foreignNames):
      return LibraryStoreReady(file, store, origin, foreignNames, engine.close);
    case StoreNotOpened(:final problem):
      await engine.close();
      return switch (problem) {
        StoreAlreadyOpen() => LibraryStoreHeldElsewhere(file),
        OpenStorageFailed(:final failure) => LibraryStoreRefused(file, failure),
        EngineTooSmall(:final limit) => LibraryStoreTooSmall(file, limit),
      };
  }
}
