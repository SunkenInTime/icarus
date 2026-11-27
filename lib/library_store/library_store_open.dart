import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_store/library_store_sqlite.dart';
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
  const LibraryStoreReady(
    super.file,
    this.store,
    this.origin,
    this.foreignNames,
    this.closeEngine,
  );

  final LibraryStore store;
  final StorageOrigin origin;
  final List<ForeignName> foreignNames;
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

final libraryStoreProvider =
    NotifierProvider<LibraryStoreNotifier, LibraryStoreState>(
  LibraryStoreNotifier.new,
);

class LibraryStoreNotifier extends Notifier<LibraryStoreState> {
  LibraryStoreNotifier({this.wrapEngine});

  final StorageEngine Function(StorageEngine engine)? wrapEngine;
  Future<void> _turn = Future<void>.value();
  Future<void>? _closing;

  @override
  LibraryStoreState build() => const LibraryStoreOff();

  Future<T> _inTurn<T>(Future<T> Function() task) {
    final run = _turn.then((_) => task());
    _turn = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<LibraryStoreOpened> open(File file, {String build = ''}) {
    _closing = null;
    return _inTurn(() async {
      state = LibraryStoreOpening(file);
      final opened =
          await openLibraryStore(file, build: build, wrapEngine: wrapEngine);
      state = opened;
      return opened;
    });
  }

  Future<void> close() => _closing ??= _inTurn(_close);

  Future<void> _close() async {
    switch (state) {
      case LibraryStoreReady(:final store, :final closeEngine):
        final released = await store.close();
        await closeEngine();
        state = LibraryStoreClosed(released);
      case LibraryStoreOff() ||
            LibraryStoreOpening() ||
            LibraryStoreClosed() ||
            LibraryStoreHeldElsewhere() ||
            LibraryStoreRefused() ||
            LibraryStoreTooSmall():
        break;
    }
  }
}
