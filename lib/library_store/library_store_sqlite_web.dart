import 'dart:io';

import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus_library/icarus_library.dart';

Future<LibraryStoreOpened> openLibraryStore(File file) async =>
    LibraryStoreRefused(
      file,
      const DeviceFailure('the web build keeps no library on this device'),
    );
