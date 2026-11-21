import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

String _seen(Object error) => switch (error) {
  PathNotFoundException(:final osError) =>
    'PathNotFoundException errno ${osError?.errorCode}',
  PathAccessException(:final osError) =>
    'PathAccessException errno ${osError?.errorCode}',
  FileSystemException(:final osError) =>
    '${error.runtimeType} errno ${osError?.errorCode}',
  _ => '${error.runtimeType}',
};

void _churn((String, int) start) {
  final (path, rounds) = start;
  final header = Uint8List(512)..[16] = 1;
  for (var round = 0; round < rounds; round++) {
    try {
      File(path).writeAsBytesSync(header, flush: false);
      File(path).deleteSync();
    } on FileSystemException {
      continue;
    }
  }
}

Map<String, int> _tally(String Function() step, int rounds) {
  final seen = <String, int>{};
  for (var round = 0; round < rounds; round++) {
    final outcome = step();
    seen[outcome] = (seen[outcome] ?? 0) + 1;
  }
  return seen;
}

String _lengthOf(String path) {
  try {
    File(path).lengthSync();
    return 'length read';
  } on FileSystemException catch (error) {
    return 'length: ${_seen(error)}';
  }
}

String _headOf(String path) {
  try {
    final file = File(path).openSync();
    try {
      file.readSync(20);
      return 'head read';
    } finally {
      file.closeSync();
    }
  } on FileSystemException catch (error) {
    return 'head: ${_seen(error)}';
  }
}

String _deleteOf(String path) {
  try {
    File(path).deleteSync();
    return 'deleted';
  } on FileSystemException catch (error) {
    return 'delete: ${_seen(error)}';
  }
}

Future<void> main(List<String> arguments) async {
  final folder = Directory(arguments.single)..createSync(recursive: true);
  stdout.writeln(
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
  );

  final journal = '${folder.path}${Platform.pathSeparator}race.sqlite-journal';
  final churning = Isolate.run(() => _churn((journal, 20000)));
  final lengths = <String, int>{};
  final heads = <String, int>{};
  for (var round = 0; round < 20000; round++) {
    final length = _lengthOf(journal);
    lengths[length] = (lengths[length] ?? 0) + 1;
    final head = _headOf(journal);
    heads[head] = (heads[head] ?? 0) + 1;
  }
  await churning;
  stdout.writeln(
    'a journal created and deleted 20000 times by another isolate',
  );
  stdout.writeln('  sizing it: $lengths');
  stdout.writeln('  opening and reading its header: $heads');

  final held = '${folder.path}${Platform.pathSeparator}held.sqlite';
  final db = sqlite3.open(held)
    ..execute('PRAGMA locking_mode = EXCLUSIVE')
    ..execute('PRAGMA journal_mode = DELETE')
    ..execute('CREATE TABLE t (x)')
    ..execute('BEGIN EXCLUSIVE')
    ..execute('INSERT INTO t VALUES (1)');
  final heldJournal = '$held-journal';
  stdout.writeln(
    'a library and its journal held open by SQLite mid-transaction',
  );
  for (final path in [held, heldJournal]) {
    stdout.writeln(
      '  ${path.split(Platform.pathSeparator).last}: '
      '${_tally(() => _lengthOf(path), 1)} ${_tally(() => _headOf(path), 1)} '
      '${_deleteOf(path)}',
    );
  }
  db
    ..execute('ROLLBACK')
    ..close();

  final plain = '${folder.path}${Platform.pathSeparator}plain.bin';
  File(plain).writeAsBytesSync(Uint8List(512));
  final handle = File(plain).openSync();
  stdout.writeln('a file held open by a Dart handle, then deleted');
  stdout.writeln('  delete: ${_deleteOf(plain)}');
  stdout.writeln(
    '  then sizing: ${_lengthOf(plain)}, opening: ${_headOf(plain)}, '
    'exists: ${File(plain).existsSync()}',
  );
  handle.closeSync();
  stdout.writeln(
    '  after the handle closed: sizing: ${_lengthOf(plain)}, '
    'exists: ${File(plain).existsSync()}',
  );
  folder.deleteSync(recursive: true);
  stdout.writeln('done');
}
