import 'dart:io';

import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

Future<LibraryStoreOpened> openLibraryStore(File file) async {
  try {
    await file.parent.create(recursive: true);
  } on FileSystemException catch (error) {
    return LibraryStoreRefused(file, DeviceFailure('$error'));
  }
  final engine = SqliteEngine(file.path);
  switch (await LibraryStore.open(engine, canRead: appCanRead)) {
    case StoreOpened(:final store):
      return LibraryStoreReady(file, store, engine.close);
    case StoreNotOpened(:final problem):
      await engine.close();
      return switch (problem) {
        StoreAlreadyOpen() => LibraryStoreHeldElsewhere(file),
        OpenStorageFailed(:final failure) => LibraryStoreRefused(file, failure),
        EngineTooSmall(:final limit) => LibraryStoreTooSmall(file, limit),
      };
  }
}
