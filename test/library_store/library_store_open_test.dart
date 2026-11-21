import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_store/library_store_open.dart';
import 'package:icarus/library_store/library_store_sqlite_io.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:path/path.dart' as path;

Future<Map<String, String>> filesIn(Directory directory) async => {
      for (final file in directory.listSync().whereType<File>())
        path.basename(file.path): '${file.lengthSync()} '
            '${file.lastModifiedSync().microsecondsSinceEpoch} '
            '${sha256.convert(await file.readAsBytes())}',
    };

Future<void> writeRow(File file, String key, String value) async {
  final engine = SqliteEngine(file.path);
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => throw StateError('$other'),
  };
  expect(
      await lease.commit([Put('library', key, value)]), isA<CommitApplied>());
  await lease.release();
  await engine.close();
}

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-store-open-');
    file = libraryStoreFile(directory.path);
    await file.parent.create(recursive: true);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<void> refused(Matcher failure) async {
    final opened = await openLibraryStore(file);
    expect(
      opened,
      isA<LibraryStoreRefused>().having((r) => r.failure, 'failure', failure),
    );
  }

  Future<void> refusedUntouched(Matcher failure) async {
    final before = await filesIn(file.parent);
    await refused(failure);
    expect(await filesIn(file.parent), before);
  }

  Future<void> refusedWithNoRowWritten(Matcher failure) async {
    final before = await filesIn(file.parent);
    await refused(failure);
    final after = await filesIn(file.parent);
    final companions = {
      for (final end in ['-wal', '-shm', '-journal'])
        '${path.basename(file.path)}$end'
    };
    expect(after.keys.toSet().difference({...before.keys, ...companions}),
        isEmpty);
    expect(before.keys.toSet().difference({...after.keys, ...companions}),
        isEmpty);
    expect(file.lengthSync(), greaterThan(0));
    await refused(failure);
  }

  test(
      'a library from a newer store format is refused, nothing is created or deleted but SQLite\'s own files, and its marker is still there',
      () async {
    await writeRow(file, 'format', '${storeFormat + 1}');
    await refusedWithNoRowWritten(
      isA<NewerFormat>()
          .having((f) => f.layer, 'layer', FormatLayer.store)
          .having((f) => f.found, 'found', storeFormat + 1),
    );
  });

  test(
      'a library whose format row is not a number is refused as damaged, and its marker is still there',
      () async {
    await writeRow(file, 'format', 'one');
    await refusedWithNoRowWritten(isA<DamagedLibrary>());
  });

  test('a file that is not a library is refused as damaged and left as found',
      () async {
    final random = Random(675);
    await file
        .writeAsBytes([for (var i = 0; i < 8192; i++) random.nextInt(256)]);
    await refusedUntouched(isA<DamagedLibrary>());
  });

  test(
      'an empty library file beside a log with content is refused as gone and nothing is recreated',
      () async {
    await file.writeAsBytes(const []);
    await File('${file.path}-wal').writeAsBytes(List.filled(4096, 7));
    await refusedUntouched(isA<LibraryFileGone>());
  });

  test(
      'a new library opens as created, and as existed once the store has saved',
      () async {
    final first = await openLibraryStore(file);
    expect(
        first,
        isA<LibraryStoreReady>()
            .having((r) => r.origin, 'origin', isA<StorageCreated>()));
    final ready = first as LibraryStoreReady;
    expect(
      await ready.store
          .editLibrary([PutFolder(ReadableFolder(publicId: 'f', name: 'F'))]),
      isA<Saved<LibraryEdited, LibraryRefusal>>(),
    );
    await ready.store.close();
    await ready.closeEngine();
    final second = await openLibraryStore(file);
    expect(
        second,
        isA<LibraryStoreReady>()
            .having((r) => r.origin, 'origin', isA<StorageExisted>()));
    final again = second as LibraryStoreReady;
    await again.store.close();
    await again.closeEngine();
  });
}
