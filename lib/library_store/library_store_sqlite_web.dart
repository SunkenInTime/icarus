import 'dart:io';

import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus_library/icarus_library.dart';

Future<LibraryStoreOpened> openLibraryStore(
  File file, {
  String build = '',
  StorageEngine Function(StorageEngine engine)? wrapEngine,
}) async =>
    LibraryStoreRefused(
      file,
      const DeviceFailure('the web build keeps no library on this device'),
    );
