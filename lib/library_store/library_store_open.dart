import 'dart:io';

import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:path/path.dart' as path;

File libraryStoreFile(String hiveDirectory) =>
    File(path.join(hiveDirectory, 'library_store', 'library.sqlite'));

sealed class LibraryStoreState {
  const LibraryStoreState();
}

final class LibraryStoreOff extends LibraryStoreState {
  const LibraryStoreOff();
}

final class LibraryStoreOpening extends LibraryStoreState {
  const LibraryStoreOpening(this.file);

  final File file;
}

final class LibraryStoreClosed extends LibraryStoreState {
  const LibraryStoreClosed(this.released);

  final Releasing released;
}

sealed class LibraryStoreOpened extends LibraryStoreState {
  const LibraryStoreOpened(this.file);

  final File file;
}

final class LibraryStoreReady extends LibraryStoreOpened {
  const LibraryStoreReady(super.file, this.store, this.closeEngine);

  final LibraryStore store;
  final Future<Releasing> Function() closeEngine;
}

final class LibraryStoreHeldElsewhere extends LibraryStoreOpened {
  const LibraryStoreHeldElsewhere(super.file);
}

final class LibraryStoreRefused extends LibraryStoreOpened {
  const LibraryStoreRefused(super.file, this.failure);

  final StorageFailure failure;
}

final class LibraryStoreTooSmall extends LibraryStoreOpened {
  const LibraryStoreTooSmall(super.file, this.maxKeyLength);

  final int maxKeyLength;
}

final appCanRead = CanRead(
  element: (payload) => canReadElementPayload(payload, MapValue.ascent),
  lineupGroup: appReadsLineup,
);

bool appReadsLineup(LineupGroupPayload payload) {
  final id = payload.data['id'];
  if (id is! String) return false;
  try {
    lineUpGraphFromCloudRows([
      CloudLineupRow(publicId: id, payload: payload.toJson()),
    ]);
    return true;
  } on FormatException {
    return false;
  }
}
